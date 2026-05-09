#!/bin/sh
# Download EDItX XML messages from one or more SFTP accounts into the plugin import tmp directory.

set -eu

runtime_log_level_value() {
    case "$1" in
        error) printf '%s' 0 ;;
        warn) printf '%s' 1 ;;
        info) printf '%s' 2 ;;
        notice) printf '%s' 3 ;;
        debug) printf '%s' 4 ;;
        *) printf '%s' -1 ;;
    esac
}

runtime_should_log() {
    level="$1"
    configured="${EDITX_RUNTIME_LOG_LEVEL:-info}"

    test -n "${EDITX_RUNTIME_LOG:-}" || return 1
    case "$configured" in
        off|error|warn|info|notice|debug) ;;
        *) configured=info ;;
    esac
    test "$configured" != "off" || return 1
    test "$(runtime_log_level_value "$level")" -le "$(runtime_log_level_value "$configured")"
}

runtime_log() {
    level="$1"
    shift
    message="$*"

    runtime_should_log "$level" || return 0

    runtime_dir="$(dirname "$EDITX_RUNTIME_LOG")"
    mkdir -p "$runtime_dir"
    message="$(printf '%s' "$message" | tr '\r\n' '  ')"
    printf '[%s %s] %s %s {"component":"sftp"}\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$(date '+%Z')" \
        "$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')" \
        "$message" >>"$EDITX_RUNTIME_LOG"
}

die() {
    runtime_log error "$*"
    printf '%s\n' "$*" >&2
    exit 1
}

log() {
    runtime_log info "$*"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

validate_target_name() {
    case "$1" in
        ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]*)
            die "SFTP target name '$1' is invalid. Use only letters, numbers, and underscores."
            ;;
    esac
}

target_value() {
    target="$1"
    suffix="$2"
    default_value="$3"

    if test "$target" = "__default__"; then
        eval "value=\${SFTP_${suffix}:-}"
    else
        validate_target_name "$target"
        eval "value=\${SFTP_${target}_${suffix}:-}"
    fi

    test -n "${value:-}" || value="$default_value"
    printf '%s' "$value"
}

require_target_var() {
    target="$1"
    suffix="$2"
    value="$3"

    test -n "$value" && return 0

    if test "$target" = "__default__"; then
        die "SFTP_$suffix is not set in $config_file."
    fi

    die "SFTP_${target}_$suffix or SFTP_$suffix is not set in $config_file."
}

quote_sftp_path() {
    printf '"%s"' "$(printf '%s' "$1" | sed 's/"/\\"/g')"
}

cleanup_target_files() {
    test -n "${stage_dir:-}" && test -d "$stage_dir" && rm -rf "$stage_dir"
    test -n "${batch_file:-}" && test -f "$batch_file" && rm -f "$batch_file"
    test -n "${remote_list_file:-}" && test -f "$remote_list_file" && rm -f "$remote_list_file"
    test -n "${downloaded_list_file:-}" && test -f "$downloaded_list_file" && rm -f "$downloaded_list_file"
    test -n "${sftp_error_file:-}" && test -f "$sftp_error_file" && rm -f "$sftp_error_file"
    stage_dir=""
    batch_file=""
    remote_list_file=""
    downloaded_list_file=""
    sftp_error_file=""
}

cleanup() {
    status=$?
    trap - EXIT INT TERM
    cleanup_target_files
    test -n "${lock_dir:-}" && test -d "$lock_dir" && rmdir "$lock_dir" 2>/dev/null || true
    exit "$status"
}

report_sftp_failure() {
    target_label="$1"
    action="$2"
    stderr_file="$3"
    stdout_file="$4"

    if test -s "$stderr_file"; then
        sftp_error_summary="$(tr '\r\n' '  ' <"$stderr_file")"
        runtime_log error "[$target_label] SFTP $action stderr: $sftp_error_summary"
        cat "$stderr_file" >&2
    fi

    if test -s "$stdout_file"; then
        sftp_output_summary="$(tr '\r\n' '  ' <"$stdout_file")"
        runtime_log error "[$target_label] SFTP $action stdout: $sftp_output_summary"
        cat "$stdout_file" >&2
    fi
}

build_sftp_args() {
    set -- -P "$target_port" \
        -oBatchMode=yes \
        -oStrictHostKeyChecking="$target_strict_host_key_checking"

    if test -n "$target_identity_file"; then
        set -- "$@" -i "$target_identity_file"
    fi
    if test -n "$target_known_hosts_file"; then
        set -- "$@" -oUserKnownHostsFile="$target_known_hosts_file"
    fi
    if test -n "$target_ssh_config"; then
        set -- "$@" -F "$target_ssh_config"
    fi

    sftp "$@" -b "$batch_file" "$target_user@$target_host"
}

run_target() {
    target="$1"
    target_label="$target"
    if test "$target" = "__default__"; then
        target_label="default"
    else
        validate_target_name "$target"
    fi

    target_host="$(target_value "$target" HOST "${SFTP_HOST:-}")"
    target_port="$(target_value "$target" PORT "${SFTP_PORT:-22}")"
    target_user="$(target_value "$target" USER "${SFTP_USER:-}")"
    target_identity_file="$(target_value "$target" IDENTITY_FILE "${SFTP_IDENTITY_FILE:-}")"
    target_known_hosts_file="$(target_value "$target" KNOWN_HOSTS_FILE "${SFTP_KNOWN_HOSTS_FILE:-}")"
    target_strict_host_key_checking="$(target_value "$target" STRICT_HOST_KEY_CHECKING "${SFTP_STRICT_HOST_KEY_CHECKING:-yes}")"
    target_ssh_config="$(target_value "$target" SSH_CONFIG "${SFTP_SSH_CONFIG:-}")"
    target_remote_dir="$(target_value "$target" REMOTE_DIR "${SFTP_REMOTE_DIR:-}")"
    target_pattern="$(target_value "$target" PATTERN "${SFTP_PATTERN:-*.xml}")"
    target_local_dir="$(target_value "$target" LOCAL_DIR "${SFTP_LOCAL_DIR:-}")"
    target_after_download="$(target_value "$target" AFTER_DOWNLOAD "${SFTP_AFTER_DOWNLOAD:-keep}")"
    target_remote_archive_dir="$(target_value "$target" REMOTE_ARCHIVE_DIR "${SFTP_REMOTE_ARCHIVE_DIR:-}")"

    runtime_log debug "[$target_label] Loaded SFTP target config: host=$target_host remote_dir=$target_remote_dir pattern=$target_pattern local_dir=$target_local_dir after_download=$target_after_download"

    require_target_var "$target" HOST "$target_host"
    require_target_var "$target" USER "$target_user"
    require_target_var "$target" REMOTE_DIR "$target_remote_dir"
    require_target_var "$target" LOCAL_DIR "$target_local_dir"

    if test -n "$target_identity_file" && ! test -r "$target_identity_file"; then
        die "$target_label: SSH identity file is not readable by the current user: $target_identity_file"
    fi

    if test -n "$target_known_hosts_file" && ! test -r "$target_known_hosts_file"; then
        die "$target_label: SSH known_hosts file is not readable by the current user: $target_known_hosts_file"
    fi

    if test -n "$target_ssh_config" && ! test -r "$target_ssh_config"; then
        die "$target_label: SSH config file is not readable by the current user: $target_ssh_config"
    fi

    case "$target_after_download" in
        archive)
            require_target_var "$target" REMOTE_ARCHIVE_DIR "$target_remote_archive_dir"
            ;;
        delete|keep)
            ;;
        *)
            die "$target_label: SFTP_AFTER_DOWNLOAD must be one of: keep, archive, delete."
            ;;
    esac

    mkdir -p "$target_local_dir" || die "$target_label: Could not create local SFTP directory: $target_local_dir"
    test -d "$target_local_dir" || die "$target_label: Local SFTP path is not a directory: $target_local_dir"
    test -w "$target_local_dir" || die "$target_label: Local SFTP directory is not writable by the current user: $target_local_dir"

    stage_dir="$(mktemp -d "$target_local_dir/.sftp-download.XXXXXX")" || die "$target_label: Could not create SFTP staging directory in $target_local_dir"
    batch_file="$(mktemp)" || die "$target_label: Could not create temporary SFTP batch file."
    remote_list_file="$(mktemp)" || die "$target_label: Could not create temporary SFTP remote list file."
    downloaded_list_file="$(mktemp)" || die "$target_label: Could not create temporary SFTP downloaded list file."
    sftp_error_file="$(mktemp)" || die "$target_label: Could not create temporary SFTP error file."
    target_downloaded=0

    runtime_log info "[$target_label] Checking remote EDItX files in $target_remote_dir."
    {
        printf 'cd %s\n' "$(quote_sftp_path "$target_remote_dir")"
        printf '%s %s\n' '-ls -1' "$target_pattern"
    } >"$batch_file"

    if ! build_sftp_args >"$remote_list_file" 2>"$sftp_error_file"; then
        report_sftp_failure "$target_label" "list" "$sftp_error_file" "$remote_list_file"
        die "$target_label: Failed to list remote EDItX files from $target_user@$target_host:$target_remote_dir."
    fi

    if ! test -s "$remote_list_file"; then
        log "[$target_label] No remote EDItX files matched $target_pattern in $target_remote_dir."
        cleanup_target_files
        return 0
    fi

    {
        printf 'lcd %s\n' "$(quote_sftp_path "$stage_dir")"
        printf 'cd %s\n' "$(quote_sftp_path "$target_remote_dir")"
        printf 'mget %s\n' "$target_pattern"
    } >"$batch_file"

    : >"$sftp_error_file"
    if ! build_sftp_args 2>"$sftp_error_file"; then
        report_sftp_failure "$target_label" "download" "$sftp_error_file" /dev/null
        die "$target_label: Failed to download EDItX files from $target_user@$target_host:$target_remote_dir."
    fi

    for file in "$stage_dir"/*.xml; do
        test -f "$file" || continue
        basename_file="$(basename "$file")"
        target_file="$target_local_dir/$basename_file"
        if test -e "$target_file"; then
            log "[$target_label] Local file already exists, skipping: $target_file"
            continue
        fi
        mv "$file" "$target_file"
        printf '%s\n' "$basename_file" >>"$downloaded_list_file"
        target_downloaded=$((target_downloaded + 1))
        log "[$target_label] Downloaded $basename_file to $target_local_dir."
    done

    if test "$target_downloaded" -eq 0; then
        log "[$target_label] No new EDItX XML files were downloaded."
        cleanup_target_files
        return 0
    fi

    case "$target_after_download" in
        keep)
            ;;
        archive|delete)
            {
                printf 'cd %s\n' "$(quote_sftp_path "$target_remote_dir")"
                if test "$target_after_download" = "archive"; then
                    printf '%s %s\n' '-mkdir' "$(quote_sftp_path "$target_remote_archive_dir")"
                fi
                while IFS= read -r remote_file; do
                    remote_base="$(basename "$remote_file")"
                    grep -Fx -- "$remote_base" "$downloaded_list_file" >/dev/null || continue
                    if test "$target_after_download" = "archive"; then
                        printf 'rename %s %s\n' \
                            "$(quote_sftp_path "$remote_base")" \
                            "$(quote_sftp_path "$target_remote_archive_dir/$remote_base")"
                    else
                        printf 'rm %s\n' "$(quote_sftp_path "$remote_base")"
                    fi
                done <"$remote_list_file"
            } >"$batch_file"
            : >"$sftp_error_file"
            if ! build_sftp_args 2>"$sftp_error_file"; then
                report_sftp_failure "$target_label" "remote-update" "$sftp_error_file" /dev/null
                die "$target_label: Downloaded files, but failed to update remote SFTP files in $target_user@$target_host:$target_remote_dir."
            fi
            ;;
    esac

    log "[$target_label] Finished SFTP EDItX download: $target_downloaded file(s)."
    cleanup_target_files
    return 0
}

trap cleanup EXIT INT TERM

config_file="${EDITX_SFTP_CONFIG:-${1:-}}"
test -n "$config_file" || die "No SFTP config file given. Pass /etc/koha/sites/<instance>/editx-sftp.conf or set EDITX_SFTP_CONFIG."
test -f "$config_file" || die "No SFTP config file: $config_file"
instance_label="${2:-}"
if test -z "$instance_label"; then
    instance_label="$(printf '%s\n' "$config_file" | sed -n 's#^/etc/koha/sites/\([^/]*\)/.*#\1#p')"
fi
test -n "$instance_label" || instance_label="editx"
lock_label="$(printf '%s' "$instance_label" | sed 's/[^ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-]/_/g')"
runtime_log info "Starting SFTP EDItX download for $instance_label using $config_file."

# shellcheck disable=SC1090
. "$config_file"

if test -n "${SFTP_LOG_FILE:-}"; then
    mkdir -p "$(dirname "$SFTP_LOG_FILE")"
    exec >>"$SFTP_LOG_FILE" 2>&1
fi

command -v sftp >/dev/null 2>&1 || die "No sftp command found."

lock_dir="/tmp/editx-sftp-$lock_label.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
    log "Another fetch_editx_sftp.sh run is already active for $instance_label."
    exit 0
fi

stage_dir=""
batch_file=""
remote_list_file=""
downloaded_list_file=""
sftp_error_file=""
target_downloaded=0
total_downloaded=0

for target in ${SFTP_TARGETS:-__default__}; do
    run_target "$target"
    total_downloaded=$((total_downloaded + target_downloaded))
done

log "Finished SFTP EDItX download for $instance_label: $total_downloaded file(s)."
