# Homelab Cloud

Portable Docker Compose definitions and migration tooling for Authentik, Immich, Nextcloud, Vikunja, Home Assistant, and Eclipse Mosquitto.

The complete English migration runbook is available in two formats:

- [Markdown migration guide](docs/MIGRATION_GUIDE.md)
- [Standalone HTML migration guide](docs/migration-guide.html)

## Quick commands

Validate the target host and every Compose definition:

```bash
./scripts/preflight.sh
```

Preview a complete migration backup:

```bash
sudo ./scripts/backup.sh all --full --dry-run --output /mnt/backup/homelab
```

Create it:

```bash
sudo ./scripts/backup.sh all --full --output /mnt/backup/homelab
```

Verify and preview a restore:

```bash
sudo ./scripts/restore.sh /path/to/BACKUP_DIR all --dry-run
```

Restore onto empty persistent directories:

```bash
sudo ./scripts/restore.sh /path/to/BACKUP_DIR all --confirm
```

Start or stop every stack in dependency order:

```bash
./scripts/up.sh all
./scripts/down.sh all
```

## Repository layout

```text
compose/                 Compose projects and safe .env.example files
docs/MIGRATION_GUIDE.md  Source migration runbook
docs/migration-guide.html Standalone browser-readable runbook
scripts/backup.sh        Checksummed logical/full backup creator
scripts/restore.sh       Guarded restore into an empty target
scripts/preflight.sh     Read-only host and Compose checks
scripts/up.sh             Ordered stack startup
scripts/down.sh           Ordered stack shutdown
```

Live secrets and runtime data are intentionally ignored by Git. A full backup contains them, so store and transfer it as sensitive private data.
