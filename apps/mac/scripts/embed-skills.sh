#!/usr/bin/env bash
set -euo pipefail

# Same guards as the sibling embed scripts: outside the Xcode driver the
# unset paths would expand to "/" and the rm -rf below would clobber it.
: "${SRCROOT:?SRCROOT must be set (run this from the Xcode build driver)}"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR must be set (run this from the Xcode build driver)}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH must be set (run this from the Xcode build driver)}"

# The published agent skills live at the repo root (`skills/<id>/SKILL.md`)
# so they can be read without an app; the bundle carries a copy under
# Resources/skills so `codans skill install` can link agents to the version
# that matches the installed app.
skills_source="${SRCROOT}/../../skills"
skills_destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/skills"

if [ ! -d "${skills_source}" ]; then
  echo "error: missing ${skills_source}" >&2
  exit 1
fi

rm -rf "${skills_destination}"
mkdir -p "${skills_destination}"
for skill in "${skills_source}"/*/; do
  [ -f "${skill}/SKILL.md" ] || continue
  /bin/cp -R "${skill%/}" "${skills_destination}/"
done
