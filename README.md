[![GitHub](https://img.shields.io/badge/GitHub-sosaramosalexis/deb-ombak-181717?logo=github)](https://github.com/sosaramosalexis/deb-ombak)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-blue?logo=gnu-bash)]()
[![Platform](https://img.shields.io/badge/platform-Linux-blue)]()

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
