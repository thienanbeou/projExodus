## Backup files
Full commands in [crafty-backup-audit.sh](<../scripts/crafty-backup-audit.sh>).
- IRUSModdedSV (`9eb792ca-.../4e71433a-...`): 105 files, June 4 to Sept 23, mostly daily, ~357 MB each (one outlier at 213 MB on June 7), ~37 GB total.
- IRUSMinecraftServer, active config (`f5c39984-.../fbd821ac-...`): 5 files, Sept 19 to Sept 23, ~1.7 GB each, ~8.3 GB total.
- IRUSMinecraftServer, orphaned config (`f5c39984-.../54a24221-...`): 1 file, Jan 12, 586 MB, config no longer runs.
Total: 111 files, 46 GB, matches `du -sh` on the backups folder.
![](<../images/crafty-audit.png>)

## Retention config
Screenshot of the Backup tab, IRUSMinecraftServer, below.
![](<../images/crafty-backup-config.png>)

| Name            | Status  | Max Backups   |
| --------------- | ------- | ------------- |
| Default Backup  | Standby | 0 (unlimited) |
| scheduledBackup | Standby | 5             |

- This table is IRUSMinecraftServer's config, not the culprit. Its Default Backup has never produced a file (confirmed, "No data available in table"), and scheduledBackup at Max Backups 5 is the one actually running, correctly capped.
- The real culprit is IRUSModdedSV's own "Default Backup" config, confirmed directly on its Backup tab, Max Backups: 0, storage location `/crafty/backups/9eb792ca-f698-4fef-9140-310da2b13623`, the exact folder holding the 105 uncapped files.
## Result
- Deleted 100 stale files on IRUSModdedSV, kept the 5 newest (~35 GB freed)
- Deleted the 1 orphaned file on IRUSMinecraftServer (586 MB freed)
- Backups folder: 111 files / 46 GB -> 10 files / 10 GB
- Set Max Backups: 5 on IRUSModdedSV's Default Backup config, matching IRUSMinecraftServer's working scheduledBackup config, so this doesn't refill uncapped
![](<../images/crafty-after-audit.png>)