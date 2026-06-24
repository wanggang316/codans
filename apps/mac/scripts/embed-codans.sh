#!/usr/bin/env bash
set -euo pipefail

# Mirrors the guards in embed-git-wt.sh: a stray run outside the Xcode
# build driver would expand unset paths to "/" — and the rm -rf below
# would happily clobber whatever that resolved to. Hard-fail instead.
: "${SRCROOT:?SRCROOT must be set (run this from the Xcode build driver)}"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR must be set (run this from the Xcode build driver)}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH must be set (run this from the Xcode build driver)}"
: "${CONFIGURATION_BUILD_DIR:?CONFIGURATION_BUILD_DIR must be set (run this from the Xcode build driver)}"

tc_source="${CONFIGURATION_BUILD_DIR}/codans"
tc_destination_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
tc_destination="${tc_destination_dir}/codans"

if [ ! -f "${tc_source}" ]; then
  echo "error: missing ${tc_source}. codans target should be a dependency of the app target." >&2
  exit 1
fi

rm -rf "${tc_destination_dir}"
mkdir -p "${tc_destination_dir}"
/bin/cp -f "${tc_source}" "${tc_destination}"
chmod +x "${tc_destination}"
