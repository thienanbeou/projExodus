## Introduction
- The current state of debianWozzy is unstable as the machine is old. It gets stuck at BIOS and fails to boot into Debian/CasaOS consistently upon cold bootups; furthermore there's no WoL support for a laptop board, which is needed for an onsite location that sometimes gets powercut suddenly. 
![](<./images/debianWozzy.png>)
- Therefore a migration to a more stable platform - [node1](<#target-node1>) - is necessary. 
- Codename: projExodus, as a commemorable name for the move off the old hardware.
## Migration Overview
- [Phase 1](<./docs/migration-in-detail.md#phase-1>): Dry discovery 
	- Ran read-only script that scans the inventory of debianWozzy. The script covered full service inventory
	- Which eventually led to the decision of what's staying vs. retiring
- [Phase 2](<./docs/migration-in-detail.md#phase-2>): Prepare
	- Validate migration destination 
	- Rightsizing assets 
		- Nextcloud rightsizing  
		- Drop unnecessary Crafty backups 
- Phase 3: Lift & Shift
	- Wave 1: Core services
		- Pi-hole + Unbound into an LXC, along with its current configuration
		- Vaultwarden + the monitoring stack into a Docker VM, along with their current configuration
	- Wave 1.5: Crafty
		- Crafty requires having a fast, consistent inbound connection, which is equivalent to portforwarding. I have no intention to open an online server right now, so the networking for Crafty is not a priority. Just move its current setup configuration over, along with a few backup copies, is enough.
	- Wave 2: Storage bound
		- Immich, along with its current configuration and media contents inside it
		- Nextcloud and Navidrome, along with its configuration and a few light items stored inside Nextcloud. I do have an external extra backup that can be imported into Nextcloud later and have Navidrome based on that backup once it's imported. 
- Phase 4: Retire 
	- Decommission CasaOS, Samba, Apache
	- Repurpose the ASUS laptop if needed
## Pre-migration Asset Inventory
### Source host: debianWozzy
- ASUS X550LN, i5-4200U (2C/4T), 8 GB DDR3L, single 750 GB WD7500BPKX HDD (25,932 power-on hours, SMART clean). 
- Debian 13 with CasaOS. 
- Tailscale IP 100.96.106.8, which is the tailnet's global DNS nameserver. 
	- Disk is 50% full: 317 GB used of 678 GB.

### Services

| Service       | Version        | Runs as                      | Data                                                     | Ports                                                          | Notes                                                                                                                                                                                            |
| ------------- | -------------- | ---------------------------- | -------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Pi-hole       | 2025.11.1      | Docker, host network         | /DATA/AppData/pihole/etc/pihole, 151 MB                  | 53, 80/443 web, 123 NTP                                        | Tailnet DNS points here                                                                                                                                                                          |
| Unbound       | —              | host systemd service         | /etc/unbound                                             | 5335                                                           | Pi-hole's upstream; moves with it                                                                                                                                                                |
| Vaultwarden   | :latest        | Docker, bridge               | /DATA/AppData/data, 1.6 MB                               | 10380                                                          | Published to tailnet by tsdproxy. tsdproxy needed for https enforcement. current version is `:latest`, which is `1.37.1`<br>I want to retain this exact version when migrated for compatibility. |
| Nextcloud     | BigBear 32.0.3 | Docker, CasaOS app           | html 150 GB (146 GB of it the PvO v4 folder)             | 7580 → 80                                                      | With Postgres 14.2 (183 MB), Redis, cron. <br>Needs manual rightsizing before migrating it. PvO v4 is affordable to drop, since I have another external copy exists                              |
| Navidrome     | 0.58.5         | Docker, CasaOS app           | data 210 MB                                              | 4533                                                           | /music is Nextcloud's PvO v4 folder                                                                                                                                                              |
| Immich        | v2.5.3         | Docker, CasaOS app           | photos 89 GB, DB 275 MB, model cache 786 MB              | 2283                                                           | pgvecto-rs PG14, Redis, ML; healthcheck broken, not corrupt                                                                                                                                      |
| Crafty        | 4.4.11         | Docker, CasaOS app           | servers 2.1 GB, backups 45 GB, logs 408 MB, config 98 MB | 8111 → 8443 UI, 8112 → 8123 Dynmap, 19132/udp, 25500–25600/tcp | Minecraft on 25565, public port forward (currently intentionally blocked down on gateway router). Needs backup rightsizing before migration.                                                     |
| Prometheus    | :latest        | Docker compose, ~/monitoring | volume 1.2 GB                                            | 9090                                                           | Config at ~/monitoring/prometheus/prometheus.yml                                                                                                                                                 |
| Grafana       | :latest        | Docker compose               | volume 52 MB                                             | 3000                                                           |                                                                                                                                                                                                  |
| node_exporter | :latest        | Docker compose               | mounts / read-only                                       | 9100                                                           | Stays per host                                                                                                                                                                                   |
| cAdvisor      | :latest        | Docker compose               | —                                                        | 8080                                                           | Stays per host                                                                                                                                                                                   |
| Blackbox      | :latest        | Docker compose               | —                                                        | 9115                                                           | Config at ~/monitoring/blackbox/blackbox.yml                                                                                                                                                     |
| tsdproxy      | :latest        | Docker compose, ~/tsdproxy   | 156 KB, docker.sock                                      | —                                                              | Publishes Vaultwarden, Nextcloud, Navidrome                                                                                                                                                      |

Retiring, not migrating: CasaOS and the rclone, devmon and mergerfs helpers it brought in; Samba, which has only the default homes and printers sections; Apache serving the default site on 8081; and the desktop stack of lightdm, cups, ModemManager and wpa_supplicant.

### Data
287 GB total under /DATA. Roughly 280 GB of it is bulk: Nextcloud 150 GB, Immich photos 89 GB, Crafty backups 45 GB. The rest, about 5 GB, is small state: all databases, configs, Pi-hole, Vaultwarden, monitoring and the Minecraft server itself.

### Target: node1
- i5-8400 tiny PC (6C/6T, turbo disabled so it runs at 2.8 GHz, powersave governor), 16 GB DDR3L, 256 GB SSD. 
- Proxmox VE, hostname pve, static 192.168.2.149 on the R3P's LAN. 
- Storage splits into a 69 GB root LV and a 141 GB thin pool for VM and container disks, which is the ceiling the whole current debianWozzy setup can't fit under (its old HDD disk is still in good shape though, reported by `smartctl` SMART overall-health self-assessment test result, which will eventually be repurpose as a bulk storage disk for node1).  
- Memtest and stress-ng both passed. 
- Wake-on-LAN works end to end from the R3P, including at boot. 
- On a DC UPS.

### Network
- The ASUS sits on the Viettel LAN at 192.168.1.0/24. 
- node1 sits behind the R3P on 192.168.2.0/24, and the R3P still reaches the Viettel router over a 2.4 GHz Wi-Fi uplink with its own NAT. 
- The ES208G switch arriving should change that picture, and internet rewiring between the current hardware deck is needed before proceeding.


## Migration Aftermath
- ....