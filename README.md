<p align="center">
  <img src="https://img.shields.io/badge/shell-blue?logo=bash&style=flat-square" alt="Shell">
</p>

# Deb OMBak — OMV Backup Utility

Schedule and manage backups for OpenMediaVault drives using rsync and systemd timers.

## Quick Start

```bash
su -
bash <(curl -fsSL https://raw.githubusercontent.com/sosaramosalexis/deb-ombak/main/install.sh)
```

## Features

- **Select source/destination** — pick drives by UUID from detected block devices
- **Full drive or specific folders** — back up entire partition or selected directories
- **Scheduled backups** — set days of week and time via systemd timer
- **Run on demand** — trigger any backup job immediately
- **Logging** — all activity logged to `/var/log/deb-ombak/` per job
- **View & delete logs** — browse, read, and clean up logs from within the tool

## Dependencies

- `rsync` — for file transfers
- `whiptail` — UI
- `util-linux` — for `lsblk` and UUID detection
