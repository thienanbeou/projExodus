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
### Wave 1: Pi-hole + Unbound (pihole-dns LXC)
- Sizing
	- 1 vCPU / 512MB RAM / 4GB disk.
- Tailscale-in-LXC gotcha
	- Unprivileged containers need `/dev/net/tun` explicitly granted from the Proxmox host before Tailscale will start. Fixed via [enable-lxc-tun.sh](<../scripts/enable-lxc-tun.sh>) (`lxc.cgroup2.devices.allow: c 10:200 rwm` + `lxc.mount.entry: /dev/net dev/net none bind,create=dir` in the container's `.conf`, then restart).
- The listeningMode gotcha
	- Pi-hole's default `listeningMode = LOCAL` silently drops queries from Tailscale-sourced clients, since Tailscale's mesh routing doesn't present as a normal local subnet to FTL. Symptom: works fine from localhost, works fine from LAN, times out specifically for tailnet-sourced queries once nothing else is around to answer. Fix: `pihole-FTL --config dns.listeningMode ALL` + restart.
- R3P `accept-dns=false` decision
	- R3P is itself a tailnet member, so without this it would passively inherit the DNS policy meant for personal devices, coupling its own system resolution (NTP, package checks) to this stack's uptime. Opted out deliberately, backed by the same pattern found in OpenWrt/Tailscale's own GitHub issues of routers/exit-nodes commonly running with this flag for exactly this reason.
- Cutover validation
	- Tested from my Legion laptop and from debianWozzy itself (now just an ordinary tailnet client) post-removal of debianWozzy's old nameserver entry, confirmed both real resolution and ad-blocking work correctly with only `pihole-dns` active.