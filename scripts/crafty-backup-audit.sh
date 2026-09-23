#!/usr/bin/env bash
# Read-only audit of Crafty backup files and retention config.
# Run on debianWozzy before any pruning.

echo "== Backup files by server/config folder =="
find /DATA/AppData/crafty/backups -mindepth 2 -maxdepth 2 -type d \
  -exec sh -c 'echo "{}"; find "{}" -type f | wc -l; du -sh "{}"' \;

echo
echo "== Full file listing with size and date =="
find /DATA/AppData/crafty/backups -maxdepth 3 -type f -exec ls -lh {} \;

echo
echo "== Totals =="
find /DATA/AppData/crafty/backups -type f | wc -l
du -sh /DATA/AppData/crafty/backups

echo
echo "== Config/db locations (for retention settings) =="
find /DATA/AppData/crafty -iname '*.db' -o -iname '*config*' 2>/dev/null