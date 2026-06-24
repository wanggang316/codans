#!/usr/bin/env bash
set -euo pipefail

# Guard SRCROOT like embed-git-wt.sh — even though we don't `rm -rf`
# here, a confusing "missing `/ThirdParty/git-wt/wt`" error on an unset
# SRCROOT is worth trading for an explicit "SRCROOT must be set" abort.
: "${SRCROOT:?SRCROOT must be set (run this from the Xcode build driver)}"

wt_script="${SRCROOT}/ThirdParty/git-wt/wt"
if [ ! -f "${wt_script}" ]; then
  echo "error: missing ${wt_script}. run: git submodule update --init apps/mac/ThirdParty/git-wt" >&2
  exit 1
fi

if [ ! -x "${wt_script}" ]; then
  echo "error: ${wt_script} is not executable" >&2
  exit 1
fi
