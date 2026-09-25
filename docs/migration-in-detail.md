---
aliases:
  - Migration In-detail
---
## Phase 1
- Ran [homelab-inventory.sh](<../scripts/homelab-inventory.sh>) against debianWozzy: read only, made no changes to the running system. 
- Collected, per service: name, version, runtime type (Docker, CasaOS-managed Docker, or host systemd), data paths and sizes, ports, and network config. Full results in [Pre-migration Asset Inventory](<../README.md#pre-migration-asset-inventory>): 14 services, 287 GB total data. 
- Staying vs. retiring, decided from these results: 
	- **Retiring:** CasaOS and its rclone, devmon, and mergerfs helpers, which are redundant once Proxmox handles storage and VM management directly. Samba, which only has the default homes and printers shares with nothing depending on it. Apache, which only serves an unused default site on 8081. The desktop stack (lightdm, cups, ModemManager, wpa_supplicant), leftover from running a GUI on a laptop and not needed on a headless target. Winbind, Avahi-daemon. 
	- **Staying:** every service in the Asset Inventory table, migrating per its assigned wave. 

![](<../images/homelab-inventory.png>)

## Phase 2
- Validated migration destination (node1): 
	- Ran memtest and stress-ng: both passed
	- Confirmed Wake-on-LAN end to end from the R3P, including at cold boot 
	- Set static IP 192.168.2.149 and hostname pve behind the R3P 
	- Partitioned storage: 69 GB root LV, 141 GB thin pool for VM/CT disks
	- Confirmed DC UPS is powering node1 
	Full commands and output in [node1-validation](<./node1-validation.md>)
- Rightsizing assets:  
	- Nextcloud rightsizing:
		- Decision: keep config (config.php, Postgres DB with users, apps, shares) and drop all file data (full 150GB html volume, PvO v4 included), since a safe external copy of PvO v4 exists
		- Post restore step (not yet done, planned for after migration): run `occ files:cleanup` on node1 to clear orphaned filecache entries left by the dropped files, so the instance doesn't carry stale references
		- Consequence: Nextcloud drops out of the storage bound tier, shrinking bulk data to roughly Immich's 89GB plus Crafty's ~8.3GB (both under node1's 141GB thin pool), and reclassifies from Wave 2 to Wave 1.5 alongside Navidrome and Crafty, since it's now config only rather than storage bound
		- Open: Wave 1 / Wave 1.5 Docker host colocation, still pinned from earlier
	- Crafty: 
		- Audited both servers' backup folders on disk and cross checked against Crafty's Backup tab
		- IRUSModdedSV: culprit. Its "Default Backup" config had Max Backups: 0 (unlimited), producing 105 uncapped files since June, ~37 GB
		- IRUSMinecraftServer: fine. Its "scheduledBackup" config (Max Backups: 5) was working correctly, ~8.3 GB. Also had 1 orphaned backup (586 MB) from a dead config
		- Fix: capped IRUSModdedSV's Default Backup at 5, deleted 100 stale files (~35 GB freed) plus the orphaned one
		Full audit in [crafty-backup-audit](<./crafty-backup-audit.md>)

## Phase 3 
### Wave 1: 
#### Pi-hole and Unbound (pihole-dns LXC)
- Sizing
	- 1 vCPU / 512MB RAM / 4GB disk.
- Tailscale-in-LXC gotcha
	- Unprivileged containers need `/dev/net/tun` explicitly granted from the Proxmox host before Tailscale will start. Fixed with [enable-lxc-tun.sh](<../scripts/enable-lxc-tun.sh>):  
```shell
 ./enable-lxc-tun.sh <CTID>  
```
- The listeningMode gotcha
	- Pi-hole's default `listeningMode = LOCAL` silently drops queries from Tailscale-sourced clients, since Tailscale's mesh routing doesn't present as a normal local subnet to FTL. Symptom: works fine from localhost, works fine from LAN, times out specifically for tailnet-sourced queries once nothing else is around to answer. Fix: `pihole-FTL --config dns.listeningMode ALL` + restart.
- R3P `accept-dns=false` decision
	- R3P is itself a tailnet member, so without this it would passively inherit the DNS policy meant for personal devices, coupling its own system resolution (NTP, package checks) to this stack's uptime. Opted out deliberately, backed by the same pattern found in OpenWrt/Tailscale's own GitHub issues of routers/exit-nodes commonly running with this flag for exactly this reason.
- Cutover validation
	- Tested from my Legion laptop and from debianWozzy itself (now just an ordinary tailnet client) post-removal of debianWozzy's old nameserver entry, confirmed both real resolution and ad-blocking work correctly with only `pihole-dns` active.
#### Monitoring Stack
- Sizing
	- 1 vCPU / 1GB RAM / 8GB disk.
- Provisioning
	- Unprivileged LXC on node1, CTID 102, hostname `monitoring`, Debian 13 template.
	- Tailscale-only, no static LAN IP, unlike pihole-dns which has a router-side DHCP reservation since it needs to be reachable as a DNS server.
- Tailscale-in-LXC gotcha
	- Same `/dev/net/tun` issue as the pihole-dns LXC. Fixed the same way, with [enable-lxc-tun.sh](<../scripts/enable-lxc-tun.sh>):
```shell
./enable-lxc-tun.sh 102
```
- Data transfer
	- Config files rsynced directly as a regular user.
	- Data lives in Docker named volumes, not bind mounts. Stopped the stack first, staged a copy through a regular-user folder on debianWozzy to dodge a sudo-over-rsync failure, then rsynced into the new host's volume paths.
- Post-copy permissions gotcha
	- Crash loop after the copy: rsync ran as root, but Prometheus and Grafana run as non-root (UID 65534 and 472). Fixed with `chown -R` to each expected UID.
- Cutover validation
	- All 5 containers healthy. Grafana's existing dashboards and data source came through intact, historical data confirmed present pre-migration.
![](<../images/postMigrationGrafana.png>)
![](<../images/postMigrationGrafana1.png>)

> [!NOTE]
> The jump in Memory Basic marks the handoff point, debianWozzy's data giving way to node1's data, both sitting in the same graph. That's concrete proof the historical data and the live host are genuinely different machines, not just a relabeled dashboard. 
> Before the jump, this is debianWozzy's old node_exporter data, whose `Total` sits at 7.64GiB, matching debianWozzy's real 8GB of RAM. After the jump, node_exporter is running inside the monitoring LXC on node1, and since it reads the host's own /proc/meminfo, therefore `Total` reflects node1's actual 16GB of physical RAM instead.

- Open item, parked deliberately
	- `prometheus.yml`'s `blackbox_tailscale_*` targets still point at debianWozzy's Tailscale address (100.96.106.8) for services not yet migrated (Vaultwarden, Nextcloud, Navidrome, Crafty). Left as is on purpose, to be redirected in one pass once the final migration wave lands rather than updated piecemeal as each service moves.