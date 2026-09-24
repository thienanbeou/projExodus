#!/usr/bin/env bash
# enable-lxc-tun.sh <ctid>
# Grants an unprivileged LXC access to /dev/net/tun, required for Tailscale.
CTID=$1
echo 'lxc.cgroup2.devices.allow: c 10:200 rwm' >> /etc/pve/lxc/${CTID}.conf
echo 'lxc.mount.entry: /dev/net dev/net none bind,create=dir' >> /etc/pve/lxc/${CTID}.conf
pct stop ${CTID}
pct start ${CTID}