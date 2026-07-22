# Preventing Empty Services After a Raspberry Pi Reboot

This document explains why Authentik, Immich, Nextcloud, or Vikunja can occasionally start as apparently fresh installations after an RPi 5 reboot. Typical symptoms are missing users, an onboarding screen, missing configuration, or an empty library.

## Short answer

Docker can start before the external disk mounted at `/srv/data` is available. The bind-mount paths then resolve to ordinary directories on the Raspberry Pi's SD card. Database containers see empty directories, initialize new databases, and the applications look unconfigured.

The original data is normally still present on the external disk. Do not create replacement users, upload files, or run onboarding while a service looks empty.

## Affected services

The following stacks depend on `/srv/data` and are affected by this failure mode:

| Stack | Critical paths |
| --- | --- |
| Authentik | `/srv/data/authentik/database`, media, templates, certificates, Redis |
| Immich | `/srv/data/immich/postgres`, `/srv/data/immich/library` |
| Nextcloud | `/srv/data/nextcloud/db`, `/srv/data/nextcloud/html`, Redis |
| Vikunja | `/srv/data/vikunja/db`, `/srv/data/vikunja/files` |

Home Assistant and Mosquitto currently store their state below the repository on the SD-card filesystem, so this specific `/srv/data` race should not reset them. If either of those services is empty, check its configured bind path separately.

## Evidence confirmed on this host

The diagnosis is based on the actual RPi 5 configuration:

1. `/srv/data` is an ext4 filesystem on the external Seagate disk partition `/dev/sda5`.
2. Its `/etc/fstab` entry contains `nofail`:

   ```text
   UUID=aa36e6dd-a595-4344-b7aa-69ca605de8a0 /srv/data ext4 defaults,nofail 0 2
   ```

   `nofail` allows the operating system to continue booting when the device is missing or late.

3. `docker.service` currently has no `RequiresMountsFor=/srv/data` dependency.
4. Every affected container has `always` or `unless-stopped` restart policy, so Docker restores it automatically during daemon startup.
5. The boot log reports:

   ```text
   srv-data.mount: Directory /srv/data to mount over is not empty, mounting anyway.
   ```

6. A read-only inspection of the SD-card root filesystem found shadow directories at:

   ```text
   /srv/data/authentik
   /srv/data/immich
   /srv/data/nextcloud
   /srv/data/vikunja
   ```

   They are hidden whenever the real disk is mounted over `/srv/data`, but Docker can use them when that mount is absent.

7. Docker bind mounts use `rprivate` propagation. If the disk mounts after a container has started, that later host mount is not reliably propagated into the already-created container bind. The container can continue using the SD-card directory until it is stopped and started again.

During the boot inspected on 2026-07-08, `/srv/data` mounted at approximately 5.4 seconds and Docker started at approximately 15.2 seconds, so that boot was correct. The configuration still permits the opposite ordering on a slower or failed USB-disk startup.

## Exact failure sequence

1. The RPi starts and the USB disk is still spinning up, disconnected, underpowered, or temporarily unavailable.
2. Because the mount has `nofail`, boot continues without `/dev/sda5` mounted at `/srv/data`.
3. Docker starts and automatically restores containers.
4. A bind such as `/srv/data/authentik/database:/var/lib/postgresql/data` resolves to the shadow directory on the SD card.
5. PostgreSQL or MariaDB initializes a fresh database in that empty directory.
6. The application connects successfully, but the new database contains no original users or settings.
7. The external disk may mount later and hide the SD-card directories on the host.
8. Already-running containers can remain attached to the original directories because their bind propagation is private.
9. Restarting Docker or recreating the containers after the disk is mounted resolves the bind paths again, making the original data reappear.

This is usually a mount-selection problem, not deletion of the real database.

## What to do when a service looks empty

### 1. Stop writing immediately

Do not:

- create new administrator or user accounts;
- upload, delete, or reorganize files/photos;
- run application onboarding;
- restore a backup over the apparently empty database;
- copy the SD-card database into the external-disk database.

Those actions create two divergent installations and make recovery more difficult.

### 2. Check which filesystem backs the application path

Run:

```bash
findmnt -T /srv/data/authentik/database -o SOURCE,TARGET,FSTYPE,OPTIONS
findmnt -T /srv/data/immich/postgres -o SOURCE,TARGET,FSTYPE,OPTIONS
findmnt -T /srv/data/nextcloud/db -o SOURCE,TARGET,FSTYPE,OPTIONS
findmnt -T /srv/data/vikunja/db -o SOURCE,TARGET,FSTYPE,OPTIONS
```

The correct source is `/dev/sda5`, mounted at `/srv/data` with filesystem type `ext4`. If the result points to `/dev/mmcblk0p2` and target `/`, the container path is on the SD card.

Also check:

```bash
systemctl is-active srv-data.mount
systemctl status srv-data.mount --no-pager -l
lsblk -o NAME,PATH,FSTYPE,UUID,MOUNTPOINTS,MODEL
journalctl -b -u srv-data.mount -u docker.service --no-pager -o short-monotonic
```

### 3. Stop Docker before changing mounts

Stopping both the daemon and its activation socket prevents an accidental Docker CLI/API request from starting the daemon again:

```bash
sudo systemctl stop docker.service docker.socket
```

Do not mount storage over database containers that are still writing.

### 4. Mount and verify the external disk

```bash
sudo mount /srv/data
findmnt -T /srv/data/authentik/database -o SOURCE,TARGET,FSTYPE,OPTIONS
```

If the mount fails, inspect the USB connection and filesystem rather than starting Docker. Useful read-only diagnostics include:

```bash
dmesg --level=err,warn
journalctl -b -k --no-pager | grep -Ei 'usb|sda|I/O error|reset|disconnect'
sudo fsck -n /dev/sda5
```

`fsck -n` performs a read-only check. Do not run a modifying filesystem repair while `/dev/sda5` is mounted.

### 5. Start Docker only after the mount is correct

```bash
sudo systemctl start docker.service
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
```

Recheck application users and settings. If the disk is correct but the services remain empty, stop and inspect the actual container mounts before changing application data:

```bash
docker inspect authentik_postgres --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} propagation={{.Propagation}}{{println}}{{end}}'
docker inspect immich_postgres --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} propagation={{.Propagation}}{{println}}{{end}}'
docker inspect nextcloud_db --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} propagation={{.Propagation}}{{println}}{{end}}'
docker inspect vikunja-db --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} propagation={{.Propagation}}{{println}}{{end}}'
```

## Permanent systemd fix

Create and verify a full backup before changing boot behavior or testing another reboot:

```bash
cd /path/to/homelabCloud
sudo ./scripts/backup.sh all --full --output /mnt/backup/homelab
```

Make Docker require the `/srv/data` mount:

```bash
sudo systemctl edit docker.service
```

Add this drop-in:

```ini
[Unit]
RequiresMountsFor=/srv/data
After=srv-data.mount
```

Then reload systemd and inspect the effective dependency:

```bash
sudo systemctl daemon-reload
systemctl show docker.service -p RequiresMountsFor -p Requires -p After
systemd-analyze critical-chain docker.service
```

`RequiresMountsFor=/srv/data` adds requirement and ordering dependencies for the mount units needed to access that path. With the existing `nofail` entry, the operating system can still boot without the external disk, but Docker should not start successfully until the required storage is mounted.

The drop-in is stored outside this Git repository at:

```text
/etc/systemd/system/docker.service.d/override.conf
```

Back it up as part of the host-level configuration inventory.

## Verification after a controlled reboot

Only reboot after a verified full backup. After startup, run these checks before opening an application:

```bash
findmnt -T /srv/data/authentik/database -o SOURCE,TARGET,FSTYPE
systemctl status srv-data.mount docker.service --no-pager -l
journalctl -b -u srv-data.mount -u docker.service --no-pager -o short-monotonic
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

The log must show `Mounted srv-data.mount` before `Starting docker.service`. Every `/srv/data/...` lookup must resolve to `/dev/sda5`.

Then validate databases and applications:

```bash
docker exec authentik_postgres pg_isready -U authentik -d authentik
docker exec immich_postgres pg_isready -U postgres -d immich
docker exec nextcloud_db healthcheck.sh --connect --innodb_initialized
docker exec vikunja-db pg_isready -U vikunja -d vikunja
```

Finally verify users, recent data, logins, and one safe read/write operation in each application.

## USB reliability checks

The ordering fix prevents Docker from using the wrong directory, but it does not repair an unreliable disk. If `/dev/sda5` is intermittently absent:

- use the official adequate RPi 5 power supply;
- verify that the external disk/enclosure has sufficient power;
- replace suspect USB cables and avoid marginal unpowered hubs;
- inspect `dmesg`/kernel logs for USB resets, disconnects, UAS errors, and I/O errors;
- inspect SMART health with `smartctl` when supported by the USB bridge;
- verify the filesystem while unmounted during a maintenance window;
- keep a tested off-host backup.

## Shadow directories on the SD card

Do not delete the hidden SD-card directories during normal operation. They are concealed below the mounted external filesystem, and confusing the real and shadow paths can destroy the wrong data.

They should be inspected or cleaned only during a planned maintenance window when:

1. a verified full backup exists;
2. Docker is stopped;
3. the external disk is deliberately unmounted or the SD-card root is inspected read-only from another environment;
4. the operator has confirmed which filesystem is being modified.

Leaving the directories in place costs some SD-card space but is safer than an unverified deletion. The systemd dependency is the essential protection against reusing them.

## Related documentation

- [Complete server migration guide](MIGRATION_GUIDE.md)
- [Repository README](../README.md)
