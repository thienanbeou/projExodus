# Recovery Drills
> Script: [cold-drill.ps1](<../scripts/cold-drill.ps1>). Raw results: [drill-auto.csv](<../results/drill-auto.csv>) and [drill-manual.csv](<../results/drill-manual.csv>), with their transcripts [drill-auto.log](<../results/drill-auto.log>) and [drill-manual.log](<../results/drill-manual.log>).

## The Why
- projExodus happened because debianWozzy couldn't survive power loss: no Wake-on-LAN, no automatic power-on, and it routinely failed to reach POST on a cold start. The onsite location loses power without warning.
- So the one thing the new setup had to prove is that it comes back on its own, with no one on site. These drills measure that instead of assuming it.

## The recovery chain being tested
- Power goes out
	- node1 keeps running on its DC UPS. `node1-power-watch.sh` notices the network link is gone and, after about 5 minutes, shuts node1 down cleanly before the battery runs out.
- Power comes back
	- The R3P boots. `wol-node1.sh` (from `rc.local`) waits 60 s, checks whether node1 is up, and sends the magic packet if it isn't.
	- node1 boots Proxmox, which starts the guests in order: pihole-dns (with a 15 s delay), monitoring, dockerVM, immich.

## Method
- Measuring point
	- A Legion 5 15ACH6 laptop on the Viettel router, which stays powered throughout, so the instrument is outside the outage. It reaches everything over Tailscale, with `--accept-dns=false`.
- Checks: 7 of them, polled in parallel every ~2 s, all by Tailscale IP so the laptop's DNS and its cache are never involved

| Check   | Target                                | Passes when                    |
| ------- | ------------------------------------- | ------------------------------ |
| host    | Proxmox web UI, `:8006`               | HTTP 2xx/3xx                   |
| dns     | pihole-dns                            | resolves `example.com`         |
| vault   | Vaultwarden via tsdproxy, `/alive`    | HTTP 2xx/3xx                   |
| cloud   | Nextcloud via tsdproxy, `/status.php` | HTTP 2xx/3xx                   |
| music   | Navidrome via tsdproxy                | HTTP 2xx/3xx                   |
| immich  | Immich, `/api/server/ping`            | HTTP 2xx/3xx                   |
| grafana | Grafana, `/api/health`                | HTTP 2xx/3xx                   |

- A trial counts as recovered when all 7 pass; 15 minutes without that counts as a failure.
- Guards
	- Before every trial, all 7 checks must pass, so each trial starts from a healthy stack.
	- Every round, the script checks the laptop's own Tailscale. If the instrument fails, the trial is flagged `instrument_ok=False` and left out of the stats.
	- The run stops at the first problem instead of power cycling a broken stack.
- Real power cut
	- The R3P, the switch and node1's UPS brick share one power strip, which is switched off. The Viettel router and the laptop stay on.
	- The strip stays off for 480 s, then is switched back on. The timer starts at that moment.
	- After recovery, the script reads the last line of node1's previous-boot journal: that's the moment node1 powered off, and the shutdown messages before it show whether it was clean.
- Simulated outage (unattended)
	- `poweroff` node1 over SSH, wait until the R3P can't ping it 3 times in a row, wait 30 s more, then `reboot` the R3P. The timer starts when the reboot command is sent.
	- This exercises the WoL chain and the boot order, but not the power watcher, the UPS, the switch losing power, or the R3P cold booting. That's what the real cuts are for.

## Results
### Real power cut: 3 of 3 recovered

| Power restored      | node1 off after the cut | Clean shutdown | Full recovery |
| ------------------- | ----------------------- | -------------- | ------------- |
| 2026-09-28 12:26:51 | 364 s                   | yes            | 210 s         |
| 2026-09-28 12:45:21 | 354 s                   | yes            | 220 s         |
| 2026-09-28 12:59:22 | 359 s                   | yes            | 210 s         |

- Median 210 s, worst 220 s.
- node1 powered off before power returned in every trial, so every trial genuinely exercised the power watcher.
- The UPS only got about 10 and 6 minutes of recharge between cuts (the plan was 25), and still carried node1 through a clean shutdown each time.
### Simulated outage: 20 of 20 recovered
- Median 219 s, mean 219.4 s, range 215 to 224 s. A 9 s spread across 20 trials.
### When each service came back (median, seconds)

| Service | Simulated (20) | Real cut (3) |
| ------- | -------------- | ------------ |
| host    | 163            | 158          |
| dns     | 163.5          | 161          |
| grafana | 190.5          | 184          |
| vault   | 211.5          | 206          |
| music   | 211            | 206          |
| cloud   | 213            | 204          |
| immich  | 219            | 210          |

## Findings
- About 60 s of the ~160 s it takes node1 to become reachable is the deliberate wait in `wol-node1.sh`. It's the obvious knob if recovery ever needs to be faster.
- The boot order holds: the LXCs answer within about 30 s of the host, the VMs about 20 s after that, and Immich is usually the last service up, which sets the total.
- Real cuts come out about 9 s faster than simulated outages because the simulated timer starts at the reboot command and includes the R3P shutting itself down first. After a real cut, the R3P starts booting the instant power returns.
- While node1 is down, the whole tailnet loses DNS, since pihole-dns is its only nameserver. The drills worked around it (`--accept-dns=false` on the laptop, IP-only checks), and it's listed under the README's known limitations.

## Limits of these drills
- The Viettel router was never power-cycled. In a building-wide outage, its own boot time would add to recovery.
- "Recovered" means each service answers a health check, not that every background job (Immich ML, Nextcloud cron) has caught up.
- 3 real cuts is a small sample. The 20 simulated trials back up the boot and WoL half of the chain.

## Reproduce
```powershell
cd scripts
.\cold-drill.ps1 auto -Trials 20      # unattended, about 7 min per trial
.\cold-drill.ps1 manual -Trials 3     # guided real power cuts; beeps when to cut and restore
```
Needs passwordless SSH (the `drill` key, loaded in ssh-agent) to root on node1 and the R3P.