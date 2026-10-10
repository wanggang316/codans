#!/usr/bin/env bash
set -euo pipefail

# Same guards as the sibling embed scripts: outside the Xcode driver the
# unset paths would expand to "/" and the rm -rf below would clobber it.
: "${SRCROOT:?SRCROOT must be set (run this from the Xcode build driver)}"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR must be set (run this from the Xcode build driver)}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH must be set (run this from the Xcode build driver)}"

# The built-in workflows live at the repo root (`workflows/<id>.workflow.yaml`)
# so they can be read and copied without an app; the bundle carries them
# under Resources/workflows as the lowest-precedence discovery scope.
workflows_source="${SRCROOT}/../../workflows"
workflows_destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/workflows"

if [ ! -d "${workflows_source}" ]; then
  echo "error: missing ${workflows_source}" >&2
  exit 1
fi

rm -rf "${workflows_destination}"
mkdir -p "${workflows_destination}"
for workflow in "${workflows_source}"/*.workflow.yaml; do
  [ -f "${workflow}" ] || continue
  /bin/cp "${workflow}" "${workflows_destination}/"
done
