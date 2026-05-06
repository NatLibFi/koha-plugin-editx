#!/bin/bash

# Assistive script to build a Koha plugin .kpz package on your local machine
# or inside some containers but without CI/CD. For building in CI/CD, use the
# .github/workflows/main.yml file and push tag to master on GitHub.

DEFAULT_VERSION="${1:-0.0.1}"

# set base variables:
CURRENT_DIR="$(pwd)"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# guess koha community repo path:
KOHA_COMMUNITY_REPO="${HOME}/git/koha/Koha"
[ ! -d "${KOHA_COMMUNITY_REPO}" ] && KOHA_COMMUNITY_REPO=~/git/KohaCommunity
[ ! -d "${KOHA_COMMUNITY_REPO}" ] && KOHA_COMMUNITY_REPO=~/git/Koha

PM_PATH="$(ls -1 "${SCRIPT_DIR}/Koha/Plugin/"*/*/*.pm)"
[ ! -f "${PM_PATH}" ] && { echo "Plugin file not found [${PM_PATH}]"; exit 1; }
PM_FILE="$(basename "${PM_PATH}")"
PM_SUBFOLDER="${PM_FILE%.pm}"
PM_FOLDER="$(dirname "${PM_PATH}")/${PM_SUBFOLDER}"
[ ! -d "${PM_FOLDER}" ] && { echo "Plugin folder not found [${PM_FOLDER}]"; exit 1; }
PM_FOLDER_RELATIVE="${PM_PATH#"${SCRIPT_DIR}"/}"
DATE="$(date +"%Y-%m-%d")"
VERSION="$(git -C "${SCRIPT_DIR}" describe --tags --abbrev=0 2>/dev/null | sed -e "s/v//")"
[ -z "${VERSION}" ] && { echo " - No version tag found, will default to ${DEFAULT_VERSION}"; VERSION="${DEFAULT_VERSION}"; }
RELEASE_FILE="koha-plugin-${PM_SUBFOLDER}-kk-${VERSION}.kpz"

echo "Local plugin builder. Building '${PM_SUBFOLDER}' plugin version '${VERSION}'"
echo -n " - Release file: ${RELEASE_FILE} will be put in current directory."
[ -e "${RELEASE_FILE}" ] && { echo " Old one removed."; rm "${RELEASE_FILE}"; }
echo

if [ ! -d "${KOHA_COMMUNITY_REPO}" ]; then
    echo "Koha community repo not found."
    exit 1
fi

perl_includes=(-I"${KOHA_COMMUNITY_REPO}" -I"${SCRIPT_DIR}")
[ -d ../koha-plugin-KK-base ] && perl_includes+=(-I../koha-plugin-KK-base)
perl -c "${perl_includes[@]}" "${PM_PATH}" || { echo "Perl syntax check failed!"; exit 1; }

TMP_DIR="$(mktemp -d)" || { echo "Failed to create temp directory"; exit 1; }
function cleanup {
    trap - EXIT
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

cp -r "${SCRIPT_DIR}/Koha" "${TMP_DIR}/."
find "${TMP_DIR}" -name .DS_Store -delete
SED_CMD=(sed -i)
[[ "$OSTYPE" == "darwin"* ]] && SED_CMD=(sed -i "")
"${SED_CMD[@]}" -e "s/{VERSION}/${VERSION}/g" "${TMP_DIR}/${PM_FOLDER_RELATIVE}" || { echo "Failed to set version in ${PM_FILE}"; exit 1; }
"${SED_CMD[@]}" -e "s/1900-01-01/${DATE}/g" "${TMP_DIR}/${PM_FOLDER_RELATIVE}" || { echo "Failed to set date in ${PM_FILE}"; exit 1; }
cd "${TMP_DIR}" || { echo "Failed to change directory"; exit 1; }
zip -qr "${CURRENT_DIR}/${RELEASE_FILE}" "Koha" || { echo "Failed to create zip file"; exit 1; }

cleanup
