#!/usr/bin/env bash
# homelab-inventory.sh — read-only inventory of the CasaOS box, input for the node1 migration plan.
#
#   sudo bash homelab-inventory.sh
#
# Writes /root/inventory-<host>-<date>/
#   SUMMARY.md  -> send this back (skim the Cron section for tokens first)
#   compose/    -> compose files, .env, CasaOS app defs = SECRETS, keep on the box
# plus a chmod-600 tarball of both. Restarts nothing, changes nothing outside that dir.
#
# v2: folds in the SMART, Samba, Apache, tsdproxy and immich-postgres health-log
# checks that were run by hand after the first pass, so this copy is self-contained.

set -u
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

OUT=/root/inventory-$(hostname -s)-$(date +%F)
S=$OUT/SUMMARY.md
mkdir -p "$OUT/compose" && chmod 700 "$OUT"
echo "# Inventory: $(hostname) — $(date '+%F %T')" >"$S"

# sec "Title" 'shell | pipeline'  -> fenced block in SUMMARY.md; a failing command never stops the run.
# ponytail: flat 30-min cap per section; raise it if the du over Nextcloud data gets cut off.
sec() { printf '\n## %s\n```\n' "$1" >>"$S"; timeout 1800 bash -c "$2" >>"$S" 2>&1; printf '```\n' >>"$S"; }

# ---------- host & storage ----------
sec "Host" 'hostnamectl | grep -E "hostname|Operating|Kernel|Hardware"; uptime -p; lscpu | grep -E "^Model name|^CPU\(s\)"; free -h'
sec "Disks" 'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL; echo; df -hT -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs; echo; grep -vE "^#|^$" /etc/fstab'
sec "Disk SMART health" 'for d in /dev/sd?; do [ -b "$d" ] || continue; echo "== $d"; smartctl -H -A "$d" 2>/dev/null | grep -Ei "overall-health|Reallocated_Sector|Current_Pending|Offline_Uncorr|Power_On_Hours"; done'
sec "/DATA (CasaOS data root), top 40 by size" '[ -d /DATA ] && ionice -c3 nice -n19 du -xh --max-depth=2 /DATA | sort -h | tail -40'

# ---------- network ----------
sec "Network" 'ip -br addr; echo; ip route; echo; grep -vE "^#|^$" /etc/resolv.conf'
sec "Tailscale" 'tailscale version | head -1; tailscale ip; tailscale status --peers=false; tailscale serve status'
sec "Listening ports" 'ss -tulpn'
sec "Host firewall (custom INPUT rules / ufw)" 'iptables -S INPUT; command -v ufw >/dev/null && ufw status verbose'

# ---------- host-level services & schedules (anything living outside Docker) ----------
sec "Running host services" 'systemctl list-units --type=service --state=running --no-pager --no-legend | awk "{print \$1}"'
sec "Custom units in /etc/systemd/system" 'find /etc/systemd/system -maxdepth 1 -type f \( -name "*.service" -o -name "*.timer" -o -name "*.mount" \)'
sec "Timers" 'systemctl list-timers --all --no-pager'
sec "Cron" 'grep -vE "^#|^$" /etc/crontab; for f in /etc/cron.d/* /var/spool/cron/crontabs/*; do [ -f "$f" ] && echo "== $f" && grep -vE "^#|^$" "$f"; done; ls /etc/cron.daily /etc/cron.weekly'
sec "Local scripts" 'ls -la /usr/local/bin /opt; find /root /home -maxdepth 3 -name "*.sh" -not -path "*/.*"'
sec "Samba shares" 'command -v testparm >/dev/null 2>&1 && testparm -s 2>/dev/null | grep -E "^\[|path ="'
sec "Apache vhosts" 'grep -hE "^\s*(Listen|DocumentRoot|ServerName|ProxyPass)" /etc/apache2/ports.conf /etc/apache2/sites-enabled/* 2>/dev/null'

# ---------- docker ----------
if ! command -v docker >/dev/null; then echo "docker not found" >>"$S"; else
  IDS=$(docker ps -aq | tr '\n' ' '); export IDS

  sec "Docker engine & volumes" 'docker version --format "Engine {{.Server.Version}}"; docker compose version; docker info --format "Root dir: {{.DockerRootDir}}  Driver: {{.Driver}}"; echo; docker system df; echo; docker system df -v | sed -n "/Local Volumes/,/Build cache/p"'

  F='| {{.Name}} | {{.Config.Image}} | {{.State.Status}}{{if index .State "Health"}}/{{.State.Health.Status}}{{end}} | {{.HostConfig.RestartPolicy.Name}} | {{.HostConfig.NetworkMode}} | {{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{if .HostIp}}{{.HostIp}}:{{end}}{{.HostPort}}{{end}}->{{$p}} {{end}}| {{range .Mounts}}{{if eq .Type "volume"}}vol:{{.Name}}{{else}}{{.Source}}{{end}}->{{.Destination}}{{if not .RW}}(ro){{end}}; {{end}}| {{index .Config.Labels "com.docker.compose.project"}} | {{if .HostConfig.Privileged}}privileged {{end}}{{range .HostConfig.Devices}}{{.PathOnHost}} {{end}}|'
  { printf '\n## Containers (empty compose project = plain docker run)\n'
    printf '| name | image | state | restart | network | ports | mounts | compose project | privileged/devices |\n|---|---|---|---|---|---|---|---|---|\n'
    docker inspect -f "$F" $IDS; } >>"$S" 2>&1

  sec "Docker networks -> members" 'for n in $(docker network ls -q); do docker network inspect -f "{{.Name}} [{{.Driver}}] {{range .IPAM.Config}}{{.Subnet}} {{end}}: {{range .Containers}}{{.Name}} {{end}}" "$n"; done'

  sec "tsdproxy-published containers" 'docker ps -a --filter label=tsdproxy.enable --format "{{.Names}}"'

  # Skips pseudo-mounts like / (node_exporter), /sys, /proc, /var/lib/docker (cAdvisor), docker.sock.
  sec "Container data on disk (bind sources + volumes; nested paths double-count)" 'docker inspect -f "{{range .Mounts}}{{.Source}}{{println}}{{end}}" $IDS | sort -u | grep -vE "^/$|^/(proc|sys|dev|run|var/run|boot|etc|lib|usr)(/|$)|^/var/lib/docker$" | while read -r p; do [ -d "$p" ] && ionice -c3 nice -n19 du -sxh "$p"; done | sort -h'

  sec "immich-postgres health-check log (context for the healthcheck-broken note)" 'docker inspect -f "{{range .State.Health.Log}}{{.Output}}{{end}}" immich-postgres 2>/dev/null | tail -n 5'

  # Compose files (+ neighbouring .env) of every compose-managed container, plus CasaOS app definitions.
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' $IDS | tr ',' '\n' | sort -u |
    while read -r f; do
      [ -f "$f" ] || continue
      cp --parents "$f" "$OUT/compose/"
      [ -f "$(dirname "$f")/.env" ] && cp --parents "$(dirname "$f")/.env" "$OUT/compose/"
    done
  for d in /var/lib/casaos/apps /etc/casaos; do [ -d "$d" ] && cp -r --parents "$d" "$OUT/compose/"; done
  sec "Compose files collected (copies in compose/, contain secrets)" "cd '$OUT/compose' && find . -type f | sort"
fi

tar -C /root -czf "$OUT.tar.gz" "$(basename "$OUT")" && chmod 600 "$OUT.tar.gz"
echo "Done -> $S   (bundle: $OUT.tar.gz)"