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
		- ~~Post restore step (not yet done, planned for after migration): run `occ files:cleanup` on node1 to clear orphaned filecache entries left by the dropped files, so the instance doesn't carry stale references~~
		- Superseded in Wave 2: scope changed to a fresh Nextcloud install with no config or DB carryover at all, since nothing besides file data was worth preserving. The `occ files:cleanup` step above never ran, it's moot under the fresh-install approach.
		- Consequence: Nextcloud drops out of the storage bound tier, shrinking bulk data to roughly Immich's 89GB plus Crafty's ~8.3GB (both under node1's 141GB thin pool); stays in Wave 2 alongside Vaultwarden and Navidrome, sharing one Docker VM
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
	- ~~`prometheus.yml`'s `blackbox_tailscale_*` targets still point at debianWozzy's Tailscale address (100.96.106.8) for services not yet migrated (Vaultwarden, Nextcloud, Navidrome, Crafty). Left as is on purpose, to be redirected in one pass once the final migration wave lands rather than updated piecemeal as each service moves.~~
	- done


### Wave 1.5: Crafty
- Scope changed from migrating Crafty itself to archiving what's needed and retiring the app entirely
- Container discovery: real container name is `crafty-container` (CasaOS renamed it from the compose service name), image `registry.gitlab.com/crafty-controller/crafty-4:4.4.11`, appdata at `/DATA/AppData/crafty`
- Two servers identified by UUID and mapped via backup size against the original audit:
	- `9eb792ca-f698-4fef-9140-310da2b13623` = IRUSModdedSV (NeoForge, MC 1.21.1, ~90 mods, Create-based modpack)
	- `f5c39984-36c8-4a70-a111-f7ed2b7996c9` = IRUSMinecraftServer (Fabric, live version confirmed as MC 1.21.11 via `logs/*.log.gz` grep for "Starting minecraft server version"; a stray 1.21.10 jar/version folder was present but unused and left out of the archive)
- IRUSModdedSV: determined reduction. Dropped entirely, no saves, config, or mods retained. `rm -rf` on both its server and backups folders, ~717MB reclaimed (360MB live + 357MB backups)
- IRUSMinecraftServer: archived. `world`, `mods`, `server.properties`, `eula.txt`, `ops.json`, `whitelist.json`, `banned-players.json`, `banned-ips.json`, and `fabric-1.21.11.jar` tarred to `IRUSMinecraftServer-archive-20260925.tar.gz` (947MB), verified (file count and tail of archive listing both checked) and copied off debianWozzy
- Crafty app, its Docker container, and its sqlite DB (`config/db/crafty.sqlite`) are not migrated; retired along with the rest of Crafty per the Phase 1 retiring list
- Open item: `IRUSMinecraftServer-archive-20260925.tar.gz` is consolidated and staged, waiting on Nextcloud being live on node1 (Wave 2) before final extraction there.

### Wave 2: Vaultwarden, Nextcloud and Navidrome
- For Nextcloud, scope changed from migrating Nextcloud to a fresh install, since Nextcloud was mainly used to archive Navidrome's music library - PvO v4; but now that importing PvO v4 into a freshly installed Nextcloud is more operational efficient, theres no need for Nextcloud migration.
- Provisioning: full Debian 13 minimal VM (VMID 100, "dockerVM") on node1. Sized 2 vCPU, 3GB RAM, 20GB disk; Docker Engine and compose plugin installed via get.docker.com
- Data transfer: Vaultwarden's `/DATA/AppData/data` (1.9MB) and Navidrome's `/DATA/AppData/navidrome/data` (210MB) rsynced from debianWozzy into `/srv/docker/vaultwarden/data` and `/srv/docker/navidrome/data` on dockerVM, staged through a regular-user folder first to dodge the same sudo-over-rsync issue hit in Wave 1. Both source folders were owned root:root on debianWozzy, so no chown was needed on the destination
- Navidrome's `/music` mount left commented out in compose, since it points at Nextcloud's PvO v4 folder which doesn't exist yet on this fresh install; tracks read as missing until PvO v4 is reimported, but the library index, playlists and settings all carried over intact
- tsdproxy routing: debianWozzy's tsdproxy used Docker labels rather than a central routing config (`tsdproxy.enable`, `tsdproxy.name`, and `tsdproxy.container_port` where the image doesn't declare a default). Old tailnet nodes for Vaultwarden and Navidrome deleted from the Tailscale admin console before bringing the new tsdproxy container up. Vaultwarden published as `vaultwarden`, Navidrome as `music` on container port 4533, Nextcloud as `cloud`
- Cutover validation: Vaultwarden vault loaded with all existing entries, while its version pinned at exactly `1.37.1` for compatibility; Navidrome's full library index, artwork and playlists present; Nextcloud completed first-run setup cleanly against the Postgres container. All three reachable and fast (sub-second) after the targetHostname fix
![](<../images/vaultwardenPostMigration.png>)
![](<../images/navidromePostMigration.png>)
- **Open items:** `prometheus.yml`'s `blackbox_tailscale_*` targets still point at debianWozzy's old address for all three services, now that Wave 2 has landed this is the trigger point for that single-pass update

### Wave 2.5: Crafty archive extraction
- With Nextcloud live on node1, `IRUSMinecraftServer-archive-20260925.tar.gz` transferred from debianWozzy to dockerVM over Tailscale (992MB), then extracted directly into Nextcloud's data volume at a new `MinecraftArchive` folder created via the web UI first
- Ownership fixed to `33:33` (www-data) to match Nextcloud's container user, then `occ files:scan --path="wozzy/files/MinecraftArchive"` run to index the files, since they landed on disk outside the web UI/sync client and wouldn't otherwise appear in Nextcloud's database
- Verified: all 9 items present (`mods`, `world`, four JSON files, `eula.txt`, `fabric-1.21.11.jar`, `server.properties`), 1.4GB total, matching the original archive
- Closes the last open item from Wave 1.5
![](<../images/minecraftPostMigration.png>)
![](<../images/minecraftPostMigration2.png>)
- Open item from Wave 1, `prometheus.yml`'s `blackbox_tailscale_*` targets pointing at debianWozzy's old Tailscale address, was resolved post-Wave 2: retargeted to `cloud`, `music`, and `vaultwarden.../alive`; also fixed Pi-hole's `/admin` target (a Wave 1 leftover) to point at `pihole-dns` instead of debianWozzy. The `blackbox_tailscale_crafty` job was dropped entirely, since Crafty has no migrated target and is being retired outright. Immich's target left unchanged, still pending Wave 3.

### Wave 3: Immich
- Highest-stakes wave: confirmed no second copy of the photo library exists, checked node1's free space ahead of time (141.23GB thin pool, ~124GB free; Immich needs ~90GB), and re-verified DB integrity (`data_checksums=on`, `checksum_failures=0`)
- Transfer method: two-pass rsync over Tailscale, pass 1 live with no downtime, pass 2 a delta rerun after a brief stop. DB handled separately via `pg_dumpall`/restore rather than copying the raw Postgres data directory, avoiding locale/glibc risk across machines
- Provisioning: full Debian 13 minimal VM (VMID 103, "immich") on node1, not an LXC like the rest of node1's hosts, since Immich's own docs advise against Docker in LXC. Sized 4 vCPU, 6GB RAM, single 115GB disk; Docker Engine and compose plugin installed via get.docker.com
- App stack: compose pinned `IMMICH_VERSION=v3.0.2`, `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`, and `valkey:9`, upload and DB data both under `~/immich`; storage template engine left disabled to match debianWozzy's flat layout
- Data transfer: hit a folder-ownership issue on the first attempt (containers create their skeleton as root on first boot), fixed with a chown. Ran with `--partial` and `--info=progress2`, wrapped in a retry loop after a mid-transfer network drop. Pass 1 landed 89GB matching the source exactly; pass 2 found nothing left to sync
- Database restore: dumped via `pg_dumpall` on debianWozzy, restored into the fresh node1 container; the dump's `ALTER ROLE postgres` line overwrote the container's password and broke the app's DB connection until manually reset back to the `.env` value
- Cutover validation: storage usage jumped from 7.7GiB to 96.4GiB matching the real library; timeline showing real photos and video across the correct date range; login worked with original credentials
![](<../images/immichPostMigration.png>)
- Checksum verification
	- Before wiping the source, ran a checksum-only dry run from the immich VM: `rsync -rcni --stats wozzy@100.96.106.8:/DATA/Gallery/immich/ ~/immich/library/`. This compares file content rather than just size and mtime, which matters after pass 1's mid-transfer drop and `--partial` resumes.
	- Result: exit 0, 5,233 files (94.76 GB) identical, 0 missing. The only differences were the six `.immich` marker files Immich keeps per folder for its mount check, rewritten by the new instance.
![](<../images/immichPostMigrationChecksum.png>)
- Post-migration cleanup: `prometheus.yml`'s `blackbox_tailscale_immich` target, left intentionally pointed at debianWozzy's old address (100.96.106.8:2283) since Wave 2.5, retargeted to `immich.smelt-macaroni.ts.net:2283` now that the immich VM is live and validated. Closes the last open thread from the original Wave 1 monitoring note.

### Post-migration hardening
- Thin pool audit
	- `lvs` on pve showed `local-lvm` at 82.08% (~26GB free), driven by the immich VM's disk (86% of 115GB). Allocated disks total 147GB against the 141GB pool, so the pool is overcommitted by design.
	- Confirmed `discard=on` on both VM disks (100, 103).
	- VG has 16GB VFree, kept unallocated as an emergency reserve (`lvextend -L +12G pve/data` if the pool nears 90% before the HDD lands).
- Start on boot
	- Only CT 101 (pihole-dns) had `onboot` set, with no order. Set all guests to start on boot, DNS first: 101 (order 1, 15s delay), 102 monitoring (2), 100 dockerVM (3), 103 immich (4).
- Immich version
	- Verified running `v3.0.2` (source was v2.5.3), so the version bump happened during Wave 3. 
- Nextcloud background jobs
	- Fresh install defaulted to AJAX; jobs hadn't run in 21 hours. The old BigBear install had a cron sidecar, which the fresh install lacked.
	- Added a `nextcloud-cron` service (same image and volumes, `entrypoint: /cron.sh`) and switched the admin setting to Cron.
- Nextcloud version pin
	- Pinned `nextcloud` and `nextcloud-cron` from `:latest` to `:35` (running 35.0.1), since Nextcloud can't skip major versions on upgrade. Both tags must always match, since they share `/var/www/html`.
- Monitoring coverage
	- Target audit showed blackbox checks covering every service, but node_exporter and cAdvisor only existed inside the monitoring LXC, leaving dockerVM and immich without resource metrics.
	- Added node_exporter and cAdvisor to both VMs' compose files, and extended the `node` and `cadvisor` jobs in `prometheus.yml` with `dockervm` and `immich` targets.
	- Result: all 15 targets up (3 node, 3 cadvisor, 8 blackbox, prometheus).
- Deferred
	- prometheus-pve-exporter on pve for host and thin pool metrics.

## Phase 4
- HDD health 
	- `smartctl -t long` on the WD7500BPKX before pulling it: result 
- Backup strategy 
	- The scavenged HDD becomes plain bulk storage, with no PBS. Backups for Immich and PvO v4 are planned for a future NAS on node2. Until then: single copy on node1 accepted / stopgap copy on the external drive