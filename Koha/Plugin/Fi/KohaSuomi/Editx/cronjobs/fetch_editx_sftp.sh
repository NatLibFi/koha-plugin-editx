#!/bin/sh
# Download EDItX XML messages from an SFTP account into the plugin import tmp directory.

set -eu

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_var() {
    case "$1" in
        SFTP_HOST) value="$SFTP_HOST" ;;
        SFTP_USER) value="$SFTP_USER" ;;
        SFTP_REMOTE_DIR) value="$SFTP_REMOTE_DIR" ;;
        SFTP_LOCAL_DIR) value="$SFTP_LOCAL_DIR" ;;
        SFTP_REMOTE_ARCHIVE_DIR) value="$SFTP_REMOTE_ARCHIVE_DIR" ;;
        *) die "Unknown required setting: $1" ;;
    esac
    test -n "$value" || die "$1 is not set in $config_file."
}

quote_sftp_path() {
    printf '"%s"' "$(printf '%s' "$1" | sed 's/"/\\"/g')"
}

cleanup() {
    status=$?
    trap - EXIT INT TERM
    test -n "${stage_dir:-}" && test -d "$stage_dir" && rm -rf "$stage_dir"
    test -n "${batch_file:-}" && test -f "$batch_file" && rm -f "$batch_file"
    test -n "${remote_list_file:-}" && test -f "$remote_list_file" && rm -f "$remote_list_file"
    test -n "${downloaded_list_file:-}" && test -f "$downloaded_list_file" && rm -f "$downloaded_list_file"
    test -n "${sftp_error_file:-}" && test -f "$sftp_error_file" && rm -f "$sftp_error_file"
    test -n "${lock_dir:-}" && test -d "$lock_dir" && rmdir "$lock_dir" 2>/dev/null || true
    exit "$status"
}

trap cleanup EXIT INT TERM

test -n "${KOHA_INSTANCE:-}" || die "KOHA_INSTANCE is not set."

config_file="${EDITX_SFTP_CONFIG:-${1:-/etc/koha/sites/$KOHA_INSTANCE/editx-sftp.conf}}"
test -f "$config_file" || die "No SFTP config file: $config_file"

# shellcheck disable=SC1090
. "$config_file"

SFTP_HOST="${SFTP_HOST:-}"
SFTP_USER="${SFTP_USER:-}"
SFTP_REMOTE_DIR="${SFTP_REMOTE_DIR:-}"
SFTP_LOCAL_DIR="${SFTP_LOCAL_DIR:-}"
SFTP_REMOTE_ARCHIVE_DIR="${SFTP_REMOTE_ARCHIVE_DIR:-}"

require_var SFTP_HOST
require_var SFTP_USER
require_var SFTP_REMOTE_DIR
require_var SFTP_LOCAL_DIR

SFTP_PORT="${SFTP_PORT:-22}"
SFTP_PATTERN="${SFTP_PATTERN:-*.xml}"
SFTP_AFTER_DOWNLOAD="${SFTP_AFTER_DOWNLOAD:-keep}"
SFTP_STRICT_HOST_KEY_CHECKING="${SFTP_STRICT_HOST_KEY_CHECKING:-yes}"

case "$SFTP_AFTER_DOWNLOAD" in
    archive)
        require_var SFTP_REMOTE_ARCHIVE_DIR
        ;;
    delete|keep)
        ;;
    *)
        die "SFTP_AFTER_DOWNLOAD must be one of: keep, archive, delete."
        ;;
esac

command -v sftp >/dev/null 2>&1 || die "No sftp command found."
mkdir -p "$SFTP_LOCAL_DIR"

if test -n "${SFTP_LOG_FILE:-}"; then
    mkdir -p "$(dirname "$SFTP_LOG_FILE")"
    exec >>"$SFTP_LOG_FILE" 2>&1
fi

lock_dir="/tmp/editx-sftp-$KOHA_INSTANCE.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
    log "Another fetch_editx_sftp.sh run is already active for $KOHA_INSTANCE."
    exit 0
fi

stage_dir="$(mktemp -d "$SFTP_LOCAL_DIR/.sftp-download.XXXXXX")"
batch_file="$(mktemp)"
remote_list_file="$(mktemp)"
downloaded_list_file="$(mktemp)"
sftp_error_file="$(mktemp)"

build_sftp_args() {
    set -- -q -P "$SFTP_PORT" \
        -oBatchMode=yes \
        -oStrictHostKeyChecking="$SFTP_STRICT_HOST_KEY_CHECKING"

    if test -n "${SFTP_IDENTITY_FILE:-}"; then
        set -- "$@" -i "$SFTP_IDENTITY_FILE"
    fi
    if test -n "${SFTP_KNOWN_HOSTS_FILE:-}"; then
        set -- "$@" -oUserKnownHostsFile="$SFTP_KNOWN_HOSTS_FILE"
    fi
    if test -n "${SFTP_SSH_CONFIG:-}"; then
        set -- "$@" -F "$SFTP_SSH_CONFIG"
    fi

    sftp "$@" -b "$batch_file" "$SFTP_USER@$SFTP_HOST"
}

{
    printf 'cd %s\n' "$(quote_sftp_path "$SFTP_REMOTE_DIR")"
    printf '%s %s\n' '-ls -1' "$SFTP_PATTERN"
} >"$batch_file"

if ! build_sftp_args >"$remote_list_file" 2>"$sftp_error_file"; then
    cat "$sftp_error_file" >&2
    cat "$remote_list_file" >&2
    die "Failed to list remote EDItX files."
fi

if ! test -s "$remote_list_file"; then
    log "No remote EDItX files matched $SFTP_PATTERN in $SFTP_REMOTE_DIR."
    exit 0
fi

{
    printf 'lcd %s\n' "$(quote_sftp_path "$stage_dir")"
    printf 'cd %s\n' "$(quote_sftp_path "$SFTP_REMOTE_DIR")"
    printf 'mget %s\n' "$SFTP_PATTERN"
} >"$batch_file"

build_sftp_args || die "Failed to download EDItX files from SFTP."

downloaded=0
for file in "$stage_dir"/*.xml; do
    test -f "$file" || continue
    basename_file="$(basename "$file")"
    target_file="$SFTP_LOCAL_DIR/$basename_file"
    if test -e "$target_file"; then
        log "Local file already exists, leaving downloaded copy in staging: $target_file"
        continue
    fi
    mv "$file" "$target_file"
    printf '%s\n' "$basename_file" >>"$downloaded_list_file"
    downloaded=$((downloaded + 1))
    log "Downloaded $basename_file to $SFTP_LOCAL_DIR."
done

if test "$downloaded" -eq 0; then
    log "No new EDItX XML files were downloaded."
    exit 0
fi

case "$SFTP_AFTER_DOWNLOAD" in
    keep)
        ;;
    archive|delete)
        {
            printf 'cd %s\n' "$(quote_sftp_path "$SFTP_REMOTE_DIR")"
            if test "$SFTP_AFTER_DOWNLOAD" = "archive"; then
                printf '%s %s\n' '-mkdir' "$(quote_sftp_path "$SFTP_REMOTE_ARCHIVE_DIR")"
            fi
            while IFS= read -r remote_file; do
                remote_base="$(basename "$remote_file")"
                grep -Fx -- "$remote_base" "$downloaded_list_file" >/dev/null || continue
                if test "$SFTP_AFTER_DOWNLOAD" = "archive"; then
                    printf 'rename %s %s\n' \
                        "$(quote_sftp_path "$remote_base")" \
                        "$(quote_sftp_path "$SFTP_REMOTE_ARCHIVE_DIR/$remote_base")"
                else
                    printf 'rm %s\n' "$(quote_sftp_path "$remote_base")"
                fi
            done <"$remote_list_file"
        } >"$batch_file"
        build_sftp_args || die "Downloaded files, but failed to update remote SFTP files."
        ;;
esac

log "Finished SFTP EDItX download: $downloaded file(s)."
