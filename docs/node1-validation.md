## Memory
memtester 12G, 3 loops, in-OS quick check:
- `apt install memtester -y`
- `memtester 12G 3`
- Result: 3/3 loops passed, all 18 patterns ok, no FAILURE lines
- Coverage note: only the 12 GB locked by memtester was tested; the ~4 GB used by the kernel and Proxmox services was not. A full overnight Memtest86+ pass covering all 16 GB is planned as a follow-up before heavier workloads land.

## CPU and memory under load
- `apt install stress-ng -y`
- `stress-ng --cpu 6 --vm 2 --vm-bytes 75% --verify --timeout 10m --metrics-brief`
- Result: 8/8 stressors passed (6 cpu, 2 vm), 0 failed, `--verify` found no data mismatches across 10.2 GB
- Turbo was off during this run, cores at 2.8 GHz base

## Wake-on-LAN & Static IP
- A static IP 192.168.2.149 and hostname pve was set behind the R3P via its LuCI.
- Persistent on node1: `post-up /usr/sbin/ethtool -s nic0 wol g` in `/etc/network/interfaces`
- Test, from the R3P: `etherwake -i br-lan 00:e0:4c:ad:02:54`
- Result: node1 booted and became SSH-reachable

## Storage layout
Default Proxmox installer LVM split on the 256 GB SSD, confirmed rather than manually created:
- `df -h /`, `lvs`, `pvs`
- Result: root LV 69.37 GB, data thin pool 141.23 GB, swap 8 GB, 16 GB unallocated on the PV