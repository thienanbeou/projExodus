#!/usr/bin/env bash
# enable-lxc-tun.sh <ctid>
# Grants an unprivileged LXC access to /dev/net/tun, required for Tailscale.
set -euo pipefail

CTID=${1:?Usage: enable-lxc-tun.sh <ctid>}
CONF="/etc/pve/lxc/${CTID}.conf"

if [ ! -f "$CONF" ]; then
  echo "No config found at $CONF" >&2
  exit 1
fi

if ! grep -q 'lxc.cgroup2.devices.allow: c 10:200 rwm' "$CONF"; then
  echo 'lxc.cgroup2.devices.allow: c 10:200 rwm' >> "$CONF"
fi

if ! grep -q 'lxc.mount.entry: /dev/net dev/net none bind,create=dir' "$CONF"; then
  echo 'lxc.mount.entry: /dev/net dev/net none bind,create=dir' >> "$CONF"
fi

pct stop "${CTID}"
pct start "${CTID}"