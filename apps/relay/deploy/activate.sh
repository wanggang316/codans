#!/usr/bin/env bash
# Runs on the VM: points `current` at the new release and restarts the relay.
set -euo pipefail

: "${NEW_RELEASE:?NEW_RELEASE must name a directory under /opt/codans-relay/releases}"
release_dir="/opt/codans-relay/releases/${NEW_RELEASE}"
[[ -x "${release_dir}/codans-relay" ]] || { echo "missing ${release_dir}/codans-relay" >&2; exit 1; }

mkdir -p /opt/codans-relay/shared/data
chmod 700 /opt/codans-relay/shared/data

install -m 0644 "${release_dir}/codans-relay.service" /etc/systemd/system/codans-relay.service
systemctl daemon-reload
systemctl enable codans-relay >/dev/null

ln -sfn "${release_dir}" /opt/codans-relay/current
systemctl restart codans-relay
systemctl --no-pager --lines=0 status codans-relay
