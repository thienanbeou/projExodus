## Introduction
- debianWozzy, the old homelab host, had become unstable with age. It regularly got stuck at BIOS and failed to boot into Debian/CasaOS on cold starts. On top of that, its laptop board had no Wake-on-LAN support, which the onsite location needs since it sometimes loses power without warning.
![](<./images/debianWozzy.png>)
- So everything had to move to a more stable platform: [node1](<./README.md#target-node1>).
- Codename: projExodus, commemorating the move off the old hardware.

## Migration Overview
> (for more details check out [migration-in-detail](<./docs/migration-in-detail.md>))
- [Phase 1](<./docs/migration-in-detail.md#phase-1>): Dry discovery
	- Ran a read-only script that scanned debianWozzy's full service inventory
	- Used the results to decide what stays and what retires
- [Phase 2](<./docs/migration-in-detail.md#phase-2>): Prepare
	- Validated the migration destination (node1)
	- Rightsized assets
		- Nextcloud: planned to keep config and DB while dropping the 150 GB of file data (later superseded by a fresh install in Wave 2)
		- Crafty: capped a runaway unlimited backup config and deleted ~35 GB of stale backups
- [Phase 3](<./docs/migration-in-detail.md#phase-3>): Lift & Shift
	- [Wave 1](<./docs/migration-in-detail.md#wave-1>): Core services
		- Pi-hole + Unbound moved into an LXC with their configuration, then cut over as the tailnet's DNS nameserver
		- Monitoring stack (Prometheus, Grafana, Blackbox, cAdvisor, node_exporter) moved into its own LXC with its configuration and historical data
	- [Wave 1.5](<./docs/migration-in-detail.md#wave-15-crafty>): Crafty
		- Crafty needs a fast, consistent inbound connection (effectively a port forward), and there's no plan to run a public server right now
		- Scope changed from migrating Crafty to archiving what's worth keeping and retiring the app: IRUSMinecraftServer's world, mods and configuration were archived and staged for Nextcloud; IRUSModdedSV was dropped as a determined reduction, nothing retained
	- [Wave 2](<./docs/migration-in-detail.md#wave-2-vaultwarden-nextcloud-and-navidrome>): Vaultwarden, Nextcloud and Navidrome
		- All three share one Docker VM, published to the tailnet by tsdproxy
		- Vaultwarden (pinned at 1.37.1) and Navidrome carried over with their data; Nextcloud became a fresh install, since nothing besides its file data was worth preserving
	- [Wave 2.5](<./docs/migration-in-detail.md#wave-25-crafty-archive-extraction>): Crafty archive extraction
		- The staged Minecraft archive extracted into Nextcloud and indexed, and the monitoring stack's blackbox targets retargeted to the new hosts
	- [Wave 3](<./docs/migration-in-detail.md#wave-3-immich>): Immich, the critical one (no second copy of the photo library existed)
		- Its own full Debian VM; the 89 GB library moved by two-pass rsync over Tailscale, the DB by `pg_dumpall` and restore, upgraded from v2.5.3 to v3.0.2 along the way
		- Checksum-verified against the source before the source was retired
	- [Post-migration hardening](<./docs/migration-in-detail.md#post-migration-hardening>)
		- Start-on-boot order with DNS first, Nextcloud cron and version pin, resource metrics on both VMs (all 15 scrape targets up)
- [Phase 4](<./docs/migration-in-detail.md#phase-4>): Retire
	- Pulled debianWozzy's only disk after a clean SMART long test, wiped it and turned it into node1's `hdd-thin` pool, which retires debianWozzy for good
	- Gave Nextcloud (300 GiB) and Immich (250 GiB) their own HDD data disks; databases and thumbnails stay on the SSD
	- Reimported PvO v4 into Nextcloud and pointed Navidrome's `/music` at it

## Pre-migration Asset Inventory
> [!NOTE]
> This section is a snapshot of debianWozzy before the migration. For the end state, see [Migration Aftermath](<./README.md#migration-aftermath>).

### Source host: debianWozzy
- ASUS X550LN, i5-4200U (2C/4T), 8 GB DDR3L, single 750 GB WD7500BPKX HDD (25,932 power-on hours, SMART clean).
- Debian 13 with CasaOS.
- Tailscale IP 100.96.106.8, the tailnet's global DNS nameserver.
- Disk 50% full: 317 GB used of 678 GB.

### Services

| Service       | Version        | Runs as                      | Data                                                     | Ports                                                          | Notes                                                                                                                                 |
| ------------- | -------------- | ---------------------------- | -------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Pi-hole       | 2025.11.1      | Docker, host network         | /DATA/AppData/pihole/etc/pihole, 151 MB                  | 53, 80/443 web, 123 NTP                                        | Tailnet DNS points here                                                                                                               |
| Unbound       | n/a            | host systemd service         | /etc/unbound                                             | 5335                                                           | Pi-hole's upstream; moves with it                                                                                                     |
| Vaultwarden   | :latest        | Docker, bridge               | /DATA/AppData/data, 1.6 MB                               | 10380                                                          | Published to the tailnet by tsdproxy, which is needed for HTTPS. `:latest` resolved to `1.37.1`, to be kept exactly for compatibility |
| Nextcloud     | BigBear 32.0.3 | Docker, CasaOS app           | html 150 GB (146 GB of it the PvO v4 folder)             | 7580 → 80                                                      | With Postgres 14.2 (183 MB), Redis, cron. Needs rightsizing before migrating; PvO v4 can be dropped since a separate external copy exists |
| Navidrome     | 0.58.5         | Docker, CasaOS app           | data 210 MB                                              | 4533                                                           | /music is Nextcloud's PvO v4 folder                                                                                                   |
| Immich        | v2.5.3         | Docker, CasaOS app           | photos 89 GB, DB 275 MB, model cache 786 MB              | 2283                                                           | pgvecto-rs PG14, Redis, ML; healthcheck broken, not corrupt                                                                           |
| Crafty        | 4.4.11         | Docker, CasaOS app           | servers 2.1 GB, backups 45 GB, logs 408 MB, config 98 MB | 8111 → 8443 UI, 8112 → 8123 Dynmap, 19132/udp, 25500-25600/tcp | Minecraft on 25565 with a public port forward, intentionally blocked at the gateway router. Backups need rightsizing before migrating |
| Prometheus    | :latest        | Docker compose, ~/monitoring | volume 1.2 GB                                            | 9090                                                           | Config at ~/monitoring/prometheus/prometheus.yml                                                                                      |
| Grafana       | :latest        | Docker compose               | volume 52 MB                                             | 3000                                                           |                                                                                                                                       |
| node_exporter | :latest        | Docker compose               | mounts / read-only                                       | 9100                                                           | Stays per host                                                                                                                        |
| cAdvisor      | :latest        | Docker compose               | n/a                                                      | 8080                                                           | Stays per host                                                                                                                        |
| Blackbox      | :latest        | Docker compose               | n/a                                                      | 9115                                                           | Config at ~/monitoring/blackbox/blackbox.yml                                                                                          |
| tsdproxy      | :latest        | Docker compose, ~/tsdproxy   | 156 KB, docker.sock                                      | n/a                                                            | Publishes Vaultwarden, Nextcloud, Navidrome                                                                                           |

Retiring, not migrating: CasaOS and the rclone, devmon and mergerfs helpers it brought in; Samba, which has only the default homes and printers sections; Apache serving the default site on 8081; Winbind and Avahi-daemon; and the desktop stack of lightdm, cups, ModemManager and wpa_supplicant.

### Data
287 GB total under /DATA. Roughly 280 GB of it is bulk: Nextcloud 150 GB, Immich photos 89 GB, Crafty backups 45 GB. The remaining ~5 GB is small state: all databases, configs, Pi-hole, Vaultwarden, monitoring and the Minecraft server itself.

### Target: node1
- i5-8400 tiny PC (6C/6T, turbo disabled so it runs at 2.8 GHz, powersave governor), 16 GB DDR3L, 256 GB SSD.
- Proxmox VE, hostname pve, static 192.168.2.149 on the R3P's LAN.
- Storage splits into a 69 GB root LV and a 141 GB thin pool for VM and container disks. That pool can't hold debianWozzy's 287 GB, which is what drove the rightsizing in Phase 2 and the reuse of debianWozzy's still-healthy HDD in Phase 4.
- Memtest and stress-ng both passed.
- Wake-on-LAN works end to end from the R3P, including at boot.
- On a DC UPS.

### Network
- The ASUS sits on the Viettel LAN at 192.168.1.0/24.
- node1 sits behind the R3P on 192.168.2.0/24, and the R3P reaches the Viettel router over a 2.4 GHz Wi-Fi uplink with its own NAT.
- An ES208G switch was on the way, and the wiring between the current hardware had to be redone before proceeding.

## Migration Aftermath
- Power loss recovery (see [Aftermath Simulations](<./README.md#aftermath-simulations>)):
	- After a real power cut, node1 shuts down cleanly on UPS battery about 6 minutes in, and the full stack is back a median of 210 seconds across 20 automated tests after power returns, with no one on site (3 of 3 trials)
	- The old host needed someone on site for every outage, and routinely failed to reach POST on a cold start
- Data integrity:
	- Immich: checksum dry run found 5,233 files (94.76 GB) identical, 0 missing
	- PvO v4: 3,833 files transferred, 3,833 indexed by Nextcloud, 0 errors
	- Minecraft archive: all 9 items present in Nextcloud, matching the original archive
- Downtime: DNS cut over with no gap by design (the new nameserver was added before the old one was removed). The monitoring move left an ~8 minute gap in Grafana. 

### node1 layout

| ID     | Name       | Type             | Sizing                                   | Runs                                                                                  | Boot order     |
| ------ | ---------- | ---------------- | ---------------------------------------- | ------------------------------------------------------------------------------------- | -------------- |
| CT 101 | pihole-dns | Unprivileged LXC | 1 vCPU, 512 MB RAM, 4 GB                 | Pi-hole, Unbound                                                                      | 1 (15 s delay) |
| CT 102 | monitoring | Unprivileged LXC | 1 vCPU, 1 GB RAM, 8 GB                   | Prometheus, Grafana, Blackbox, cAdvisor, node_exporter                                | 2              |
| VM 100 | dockerVM   | Debian 13 VM     | 2 vCPU, 3 GB RAM, 20 GB + 300 GiB on HDD | Vaultwarden 1.37.1, Nextcloud 35.0.1 (+ cron, Postgres 16), Navidrome 0.58.5, tsdproxy | 3              |
| VM 103 | immich     | Debian 13 VM     | 4 vCPU, 6 GB RAM, 115 GB + 250 GiB on HDD | Immich v3.0.2, Postgres (VectorChord), Valkey                                         | 4              |

Both VMs also run node_exporter and cAdvisor, so every guest reports resource metrics. All guests are reached by Tailscale name; only pihole-dns has a LAN DHCP reservation, since it has to be reachable as a DNS server.

### Storage
- `local-lvm` (SSD, 141 GB thin pool): guest OS disks, all databases, Immich thumbnails. Overcommitted by design (147 GB allocated), with `discard=on` so guests can hand freed space back, and 16 GB of VG space held back as an emergency reserve.
- `hdd-thin` (debianWozzy's old 750 GB HDD, ~684 GiB): Nextcloud data and Immich originals. 550 GiB allocated, deliberately not overcommitted, ~130 GiB left for future guests.

### Network
- node1 sits behind the R3P on 192.168.2.0/24, and the R3P still reaches the Viettel router over a 2.4 GHz Wi-Fi uplink with its own NAT.
- A TP-Link Omada ES208G switch is now installed between the R3P and node1 (192.168.2.148), resolving the rewiring flagged above.

### Retired
- CasaOS and its helpers, Samba, Apache, Winbind, Avahi-daemon and the desktop stack
- Crafty and IRUSModdedSV
- debianWozzy itself, whose only disk now lives on as `hdd-thin`

### Known limitations
- The HDD is a single point of failure for Immich originals and PvO v4. PvO v4 still has its external copy; Immich's only other copy is the frozen SSD copy of originals on the same node. Off-node backup waits on a future node2 NAS.
- No host or thin pool metrics yet; prometheus-pve-exporter on pve is deferred.
- The tailnet's only DNS nameserver is pihole-dns, so while node1 is down every tailnet device loses name resolution. Found during the recovery drills. Adding a fallback nameserver in Tailscale's DNS settings would fix it, at the cost of some queries bypassing Pi-hole during outages.

### Aftermath Simulations
> (for method, per-service timings and limits, check out [recovery-drills](<./docs/recovery-drills.md>))

| Drill                                        | Trials | Recovered | Median | Range        |
| -------------------------------------------- | ------ | --------- | ------ | ------------ |
| Real power cut (strip off 8 min, then on)    | 3      | 3         | 210 s  | 210 to 220 s |
| Simulated outage (node1 off, router reboot)  | 20     | 20        | 219 s  | 215 to 224 s |

- The power watcher shuts node1 down cleanly on UPS battery (354 to 364 s after the cut, clean every time), then the R3P wakes it by WoL once power returns.
- The simulated outages ran unattended and show how repeatable the wake and boot half is: a 9 s spread over 20 trials.
- About 60 s of every recovery is a deliberate wait: `wol-node1.sh` holds off for 60 s after the R3P boots before it tries to wake node1. Cutting it would bring the median down by up to about a minute, but it's there on purpose:
	- Power often flickers back and forth right after an outage. Waking node1 straight away risks booting it into a second cut, while its UPS is still nearly drained from the first, and that would be a hard crash with no battery left for a clean shutdown.
	- The R3P's LAN bridge and the switch need a moment to come fully up after a cold start. A magic packet sent before they're ready is simply lost.