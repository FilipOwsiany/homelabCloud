# Homelab Server Migration Guide

This is the complete runbook for moving this repository and all six services to another Linux server. It covers the application containers, databases, caches, files, secrets, networking, external dependencies, validation, cutover, and rollback.

The guide was verified against the repository state and official product documentation on 2026-07-22. Migrate with the versions pinned in this repository. Upgrade only after the restored server has passed every validation check.

## 1. Scope and safety rules

The migration includes:

- Authentik, PostgreSQL, and Redis;
- Immich, PostgreSQL, Valkey, machine learning, and all photo/video assets;
- Nextcloud, MariaDB, Redis, cron, configuration, apps, and user files;
- Vikunja, PostgreSQL, and attachments;
- Home Assistant Container, including its YAML, `.storage`, secrets, and SQLite state;
- Eclipse Mosquitto, including its password file and retained/persistent messages;
- ignored `.env` files, the exact Git revision, running-image inventory, and checksums.

Follow these rules:

1. Never migrate by copying a live PostgreSQL or MariaDB data directory. Use the logical dumps created by `scripts/backup.sh`.
2. Never start an older application version against a database written by a newer version. Restore with the repository's pinned versions first.
3. A complete migration requires `--full`. A backup without `--full` intentionally omits large Immich, Nextcloud, Vikunja, and MQTT data.
4. Treat the backup as highly sensitive. It contains passwords, application secret keys, identity data, Home Assistant credentials, photos, files, and MQTT password hashes.
5. Do not allow both servers to accept writes after cutover. Their databases will diverge.
6. Keep the old server and the verified backup unchanged until the new server has run successfully for an agreed observation period.
7. The restore script never deletes data. It stops selected Compose projects but refuses to restore over a non-empty persistent directory.

## 2. Architecture and dependency inventory

### 2.1 Service matrix

| Stack | Pinned application image | Host port | Database | Cache/worker | Authoritative files |
| --- | --- | ---: | --- | --- | --- |
| Authentik | `ghcr.io/goauthentik/server:2025.2.4` | `9000`, `9443` | PostgreSQL 15 | Redis 7, Authentik worker | media, templates, optional certificates |
| Immich | `ghcr.io/immich-app/immich-server:v2.5.6` | `2283` | Immich PostgreSQL 14/VectorChord image | Valkey 9, machine-learning cache | the complete `UPLOAD_LOCATION` |
| Nextcloud | `nextcloud:33.0.0-apache` | `8080` | MariaDB 11 | Redis 7, `/cron.sh` worker | the complete `/var/www/html` bind mount |
| Vikunja | `vikunja/vikunja:2.3.0` | `3456` | PostgreSQL 18 | built into the Vikunja container | attachment/files directory |
| Home Assistant | `ghcr.io/home-assistant/home-assistant:2026.3.1` | `8123` through host networking | SQLite inside `/config` | internal | the complete `/config` directory |
| Mosquitto | `eclipse-mosquitto:2` | `1883`, `9001` | none | internal persistence engine | config, password file, `mosquitto.db` |

Database and cache ports are not published to the host. They are reachable only inside their own Compose networks. The named Immich `model-cache` volume and cache contents are reproducible and are not required for recovery.

### 2.2 Persistent paths

| Stack | Default host path | Content | Required for restore |
| --- | --- | --- | --- |
| Authentik | `/srv/data/authentik/database` | PostgreSQL physical files | No; recreate from logical dump |
| Authentik | `/srv/data/authentik/media` | uploaded branding/media | Yes when used |
| Authentik | `/srv/data/authentik/custom-templates` | custom templates | Yes when used |
| Authentik | `/srv/data/authentik/certs` | certificate import files | Yes when used |
| Authentik | `/srv/data/authentik/redis` | cache/queue state | No; it can be rebuilt |
| Immich | `/srv/data/immich/library` | complete `UPLOAD_LOCATION`, not only the `library/` child | Yes |
| Immich | `/srv/data/immich/postgres` | PostgreSQL physical files | No; recreate from logical dump |
| Nextcloud | `/srv/data/nextcloud/html` | config, apps, themes, and user data | Yes |
| Nextcloud | `/srv/data/nextcloud/db` | MariaDB physical files | No; recreate from logical dump |
| Nextcloud | `/srv/data/nextcloud/redis` | cache/file-lock state | No; it can be rebuilt |
| Vikunja | `/srv/data/vikunja/files` | attachments and uploaded files | Yes |
| Vikunja | `/srv/data/vikunja/db` | PostgreSQL physical files | No; recreate from logical dump |
| Home Assistant | `compose/homeassistant/config` | YAML, `.storage`, secrets, registry, and SQLite | Yes |
| Mosquitto | `compose/mqtt/config` | broker config and password hashes | Yes |
| Mosquitto | `compose/mqtt/data` | retained messages and persistent sessions | Yes for exact continuity |

The paths can be changed in each service's `.env`; the `.env.example` files document the supported variables. Relative Home Assistant and MQTT paths are resolved from their Compose directory.

### 2.3 Dependency flow

```text
Internet/LAN clients
        |
        +--> DNS + TLS reverse proxy (not in this repository)
                 |--> Authentik :9000
                 |--> Immich :2283 ----OIDC discovery/login----> Authentik
                 |--> Nextcloud :8080
                 |--> Vikunja :3456
                 `--> Home Assistant :8123 (host network)

LAN IoT clients ------> Mosquitto :1883/:9001 <------ Home Assistant

Each application stack ------> its private database/cache network
```

### 2.4 Secrets that must survive

| Stack | Secret/configuration |
| --- | --- |
| Authentik | `PG_PASS`, `AUTHENTIK_SECRET_KEY`; the secret key must remain unchanged after restore |
| Immich | `DB_PASSWORD`, `DB_USERNAME`, `DB_DATABASE_NAME`, `IMMICH_VERSION`, storage paths |
| Nextcloud | MariaDB user/root passwords; restored `config.php` also contains operational configuration |
| Vikunja | `POSTGRES_PASSWORD`, `VIKUNJA_SERVICE_SECRET`, public URL |
| Home Assistant | `secrets.yaml`, `.storage/auth*`, integration tokens and device registries |
| Mosquitto | `config/passwd`; clients must continue using matching usernames and passwords |

Live `.env`, Home Assistant runtime state, databases, MQTT data, and `config/passwd` are deliberately ignored by Git. They are transferred only in the protected backup.

## 3. External dependencies not stored in this repository

Inventory and recreate all of these before cutover:

1. **DNS:** A/AAAA records for every public hostname, local split-DNS entries, and any dynamic-DNS updater. Lower DNS TTL at least one old-TTL period before migration.
2. **Static address:** reserve the target server's IP in DHCP or configure it statically. Home automation and MQTT clients often contain literal IP addresses.
3. **Reverse proxy:** preserve virtual hosts, upstream ports, forwarded headers, WebSocket support, upload limits, timeouts, and trusted-proxy settings.
4. **TLS:** copy or reissue certificates and confirm automatic renewal. Authentik OIDC requires correct hostnames, HTTPS, and accurate time.
5. **Router/NAT and firewall:** update port-forward destinations. Do not expose database/cache ports. Keep MQTT `1883` private unless TLS and strict access controls are added.
6. **SMTP:** Authentik notifications/recovery, Nextcloud mail, and Vikunja mail need an external SMTP account if those features are used.
7. **External storage:** record Immich external-library mounts, Nextcloud external-storage mounts, NFS/CIFS credentials, filesystem types, and mount ordering. These are not declared in the current Compose files.
8. **Hardware:** record Home Assistant USB device paths, Bluetooth adapters, Zigbee/Z-Wave coordinators, serial permissions, and any Immich hardware-acceleration devices.
9. **Time synchronization:** configure NTP/`systemd-timesyncd` or chrony. Incorrect time breaks TOTP, OAuth/OIDC, TLS validation, and automations.
10. **Off-host backup target:** the backup must not exist only on the source server. Prefer an encrypted external disk or an encrypted remote destination.

### Reverse-proxy upstream map

| Public service | Target upstream | Important proxy requirements |
| --- | --- | --- |
| Authentik | `http://TARGET_IP:9000` | preserve `Host` and `X-Forwarded-*`; WebSockets |
| Immich | `http://TARGET_IP:2283` | root of its own hostname, large bodies, no request buffering, long upload timeouts, WebSockets |
| Nextcloud | `http://TARGET_IP:8080` | large bodies/timeouts; configure trusted proxy and overwrite URL in Nextcloud |
| Vikunja | `http://TARGET_IP:3456` | preserve host/proto; public URL must match exactly |
| Home Assistant | `http://TARGET_IP:8123` | WebSockets; configure `trusted_proxies` when proxied |

If the reverse proxy runs on the same target server, consider binding published application ports to `127.0.0.1`. If it runs on another host, permit only that proxy and the required LAN clients. Docker-published ports can bypass normal UFW/firewalld expectations; review Docker's firewall rules explicitly.

## 4. Prepare the source server

### Step 1: confirm repository state and versions

From the repository root:

```bash
git status --short
git log -5 --oneline
git rev-parse HEAD
docker ps --no-trunc --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
./scripts/preflight.sh
```

Resolve every `FAIL`. Review each `WARN`; unreadable application directories usually mean the full backup must run with `sudo`.

Do not run `docker compose pull`, change an image tag, or upgrade a database immediately before migration. A container may display an old generic tag such as `latest`, but the application version must match the pinned repository version. The backup records running container and image identities in `meta/running-containers.tsv`.

### Step 2: inventory site-specific state

Record in a separate protected note:

- old and new LAN IPs;
- every public/local hostname and current DNS TTL;
- reverse-proxy and certificate locations;
- router forwarding rules;
- SMTP endpoints and credentials;
- OAuth redirect URIs;
- Immich external-library paths;
- Home Assistant USB paths from `ls -l /dev/serial/by-id/`;
- every MQTT client and the broker hostname it uses;
- source filesystem sizes with `sudo du -sh /srv/data/*`;
- target CPU architecture with `uname -m`.

All pinned images used here support the currently deployed `aarch64` host. Confirm multi-architecture support before moving to a different architecture or enabling hardware acceleration.

### Step 3: size the backup and target

```bash
df -h /srv/data /mnt/backup
sudo ./scripts/backup.sh all --full --dry-run --output /mnt/backup/homelab
```

The backup destination needs room for the compressed application data plus database dumps. The target needs room for restored data, container images, temporary database work, and growth. Do not use FAT32 because a large archive can exceed its 4 GiB file limit.

## 5. Create and verify the migration backup

### Step 1: create a full backup

Run this from the repository root with the external backup filesystem mounted:

```bash
sudo ./scripts/backup.sh all --full --output /mnt/backup/homelab
```

The script:

- uses logical `pg_dump`/`mariadb-dump` exports;
- temporarily quiesces file-writing services where needed;
- enables Nextcloud maintenance mode and stops its cron worker during its snapshot;
- stops Home Assistant for a consistent SQLite/config snapshot;
- archives the complete application file sets required for migration;
- restarts only containers it stopped;
- copies live `.env` files and MQTT authentication configuration;
- records Docker versions, active images, Git state, and the Git commit;
- creates `meta/repository.bundle`, which can recreate the repository without GitHub;
- writes `SHA256SUMS` and a completion marker;
- writes `INCOMPLETE` if an error interrupts the backup.

Expected layout:

```text
all_YYYY-MM-DDTHH-MM-SSZ/
├── archives/
├── config/
├── dumps/
├── meta/
│   ├── COMPLETE
│   ├── manifest.env
│   ├── repository.bundle
│   └── running-containers.tsv
├── RESTORE.txt
└── SHA256SUMS
```

### Step 2: verify it before stopping the source

Replace `BACKUP_DIR` with the timestamped directory:

```bash
cd BACKUP_DIR
sudo sha256sum --check SHA256SUMS
sudo test -f meta/COMPLETE
sudo test ! -e INCOMPLETE
sudo git bundle verify meta/repository.bundle
sudo gzip -t dumps/*.sql.gz
sudo tar -tzf archives/homeassistant-config.tar.gz >/dev/null
sudo tar -tzf archives/immich-uploads.tar.gz >/dev/null
sudo tar -tzf archives/nextcloud-html.tar.gz >/dev/null
```

Every checksum must report `OK`; `git bundle verify` must report a complete history. Do not proceed with a missing archive, failed dump test, checksum error, `INCOMPLETE`, or absent `meta/COMPLETE`.

### Step 3: establish the final write boundary

The backup script restarts services so a failed backup does not leave the homelab offline. Any writes made after the backup are not present in it. When ready for final transfer/cutover, stop the source:

```bash
cd /path/to/homelabCloud
sudo ./scripts/down.sh all
docker ps --format '{{.Names}}' | grep -E 'authentik|immich|nextcloud|vikunja|homeassistant|mosquitto' || true
```

Do not start it again unless performing a rollback. If downtime must be minimized, rehearse the process first and use an incremental external file-copy strategy designed for each application; the included archive workflow favors clarity and recoverability.

### Step 4: transfer the backup securely

An external disk is simplest. Over SSH, preserve metadata and resume interrupted transfers with:

```bash
sudo rsync -aH --info=progress2 BACKUP_DIR/ admin@TARGET_IP:/srv/migration/BACKUP_NAME/
```

Run `sha256sum --check SHA256SUMS` again on the target. Use disk encryption or an encrypted transport and restrict backup directory permissions to the administrator.

## 6. Prepare the target server

### Step 1: install the operating system and Docker

The current source is Debian 13 on `aarch64`. On a Debian 13 target, install Docker Engine from Docker's official APT repository, including these packages:

```text
docker-ce
docker-ce-cli
containerd.io
docker-buildx-plugin
docker-compose-plugin
```

Follow the current [Docker Engine for Debian](https://docs.docker.com/engine/install/debian/) instructions rather than an unofficial convenience script. Also install:

```bash
sudo apt update
sudo apt install ca-certificates curl git rsync
```

Verify the installation:

```bash
sudo systemctl enable --now docker
docker --version
docker compose version
sudo docker run --rm hello-world
timedatectl status
```

Use `sudo` for migration commands unless the administrator is in the `docker` group and can read every source archive. Membership in the `docker` group is effectively root-equivalent.

### Step 2: configure storage and mounts

Create or mount `/srv/data` on a Linux filesystem that supports Unix ownership, permissions, hard links, and large files. Do not put PostgreSQL/MariaDB data on SMB/NFS. Immich explicitly does not support its PostgreSQL data directory on a network share.

```bash
sudo mkdir -p /srv/data /srv/migration
findmnt /srv/data
df -h /srv/data /srv/migration
```

Configure every external disk/NFS/CIFS dependency in `/etc/fstab` and verify it is mounted before Docker starts. A missing mount can cause Docker to write into an empty directory on the root filesystem.

### Step 3: restore the exact repository revision

Choose one method.

From the backup bundle, which does not require network access:

```bash
cd /opt
sudo git clone /srv/migration/BACKUP_NAME/meta/repository.bundle homelabCloud
sudo chown -R ADMIN_USER:ADMIN_GROUP /opt/homelabCloud
cd /opt/homelabCloud
git switch master
git rev-parse HEAD
```

Or, after pushing these commits to the remote repository:

```bash
git clone https://github.com/FilipOwsiany/homelabCloud.git
cd homelabCloud
git switch master
git rev-parse HEAD
```

Compare the result with `GIT_COMMIT` in `BACKUP_DIR/meta/manifest.env`. Do not restore with a different revision unless the change has been reviewed for database/image compatibility.

### Step 4: choose target paths

For the same `/srv/data` layout, the restore script installs backed-up `.env` files automatically.

If paths or public URLs must change:

1. Copy each required `.env.example` to `.env`.
2. Copy the old secrets from `BACKUP_DIR/config/SERVICE/.env` without printing them.
3. Change only path, timezone, or public-URL values; preserve passwords and application secret keys.
4. Run restore with `--keep-env`.

Never commit a live `.env`.

## 7. Restore all services

### Step 1: verify the target and backup without changing data

```bash
cd /opt/homelabCloud
sudo ./scripts/restore.sh /srv/migration/BACKUP_NAME all --dry-run
```

The dry run verifies every checksum and shows the default target paths without installing secrets or stopping containers. If you selected custom paths, create the target `.env` files first and repeat the dry run so it displays those paths.

### Step 2: make sure destinations are empty

The restore script checks every authoritative data and database directory. If an earlier test start created content, stop the stack and move that content to a clearly named quarantine directory. Inspect the exact path before moving it. Do not merge a fresh database directory with restored data.

### Step 3: run the restore

For the default paths and backed-up environment files:

```bash
sudo ./scripts/restore.sh /srv/migration/BACKUP_NAME all --confirm
```

For deliberately edited target `.env` files:

```bash
sudo ./scripts/restore.sh /srv/migration/BACKUP_NAME all --keep-env --confirm
```

The automated restore order is MQTT, Authentik, Nextcloud, Immich, Vikunja, and Home Assistant. For each database-backed application it initializes an empty database container, waits for health, imports the logical dump with error-stop behavior, and only then starts the application. It applies Immich's required search-path compatibility transformation and runs Nextcloud's `maintenance:data-fingerprint` after restore.

Do not interrupt the process. If it fails, preserve the logs and the untouched backup. The script will not delete partial target data; move the partial target directories aside before retrying.

After restore, run `./scripts/preflight.sh`. Resolve every Compose, Docker-daemon, filesystem, and permission failure. Warnings about intentionally protected database directories may remain when the unprivileged administrator cannot read container-owned files.

## 8. Per-service configuration and validation

### 8.1 Authentik

**Internal dependencies**

- `authentik-server` serves the UI, API, OIDC endpoints, and embedded outpost.
- `authentik-worker` handles background work and optional outpost management.
- PostgreSQL is authoritative for users, policies, flows, applications, providers, tokens, and configuration.
- Redis is a cache/queue dependency and is intentionally rebuilt instead of restored.
- The worker mounts `/var/run/docker.sock`. This is powerful root-equivalent access; retain it only if Docker-managed outposts need it.

**Required configuration**

1. Preserve the original `AUTHENTIK_SECRET_KEY`. Changing it can invalidate encrypted application data and sessions.
2. Ensure the target resolves Authentik's public hostname and has accurate time.
3. Point the reverse proxy to port `9000`; expose `9443` only if its direct HTTPS endpoint is intentionally used.
4. Restore or reissue external reverse-proxy certificates. Files in `/srv/data/authentik/certs` are import sources, not a replacement for proxy TLS configuration.
5. Configure SMTP in Authentik if password recovery and alert email are required.
6. Do not mount `/etc/localtime` into Authentik containers; Authentik uses UTC internally.

**Immich OIDC integration**

The restored database should retain the existing provider. If it must be recreated, use a confidential OAuth2/OpenID provider with Authorization Code flow and these redirect URIs, replacing the hostname:

```text
https://immich.example.com/auth/login
https://immich.example.com/user-settings
app.immich:///oauth-callback
```

Use scopes `openid email profile`. For this installation, keep the provider subject mode based on the user's email because existing Immich users are linked that way. Changing the subject identifier can create a second identity or the error “User already exists, but is linked to another account.” The issuer pattern is:

```text
https://AUTHENTIK_HOST/application/o/PROVIDER_SLUG/.well-known/openid-configuration
```

The current documented provider slug is `rpi-immich`. Preserve its client ID and client secret. Preserve the MFA validation stage settings if TOTP enforcement is required:

```text
stage: default-authentication-mfa-validation
not_configured_action: configure
device_classes: [totp]
configuration_stages: [default-authenticator-totp-setup]
```

**Validation**

```bash
docker compose --project-directory compose/authentik ps
docker logs --tail 100 authentik_server
docker logs --tail 100 authentik_worker
docker exec authentik_postgres pg_isready -U authentik -d authentik
docker exec authentik_redis redis-cli ping
curl -I http://TARGET_IP:9000/
```

Then sign in as an administrator, confirm users/groups/applications/providers, complete a TOTP login, and check System Tasks for failures.

### 8.2 Immich

**Internal dependencies**

- PostgreSQL contains asset paths, albums, users, sharing, faces, jobs, and all metadata. Immich does not rebuild this state by scanning the asset directory.
- `UPLOAD_LOCATION` contains originals plus generated thumbnails, encoded video, profiles, upload staging, and automatic DB backups.
- Valkey is transient cache/queue state and is rebuilt.
- The machine-learning model cache is a named volume and can be downloaded again.

**Required configuration**

1. Keep `IMMICH_VERSION=v2.5.6` for the initial restore.
2. Preserve `DB_PASSWORD`, `DB_USERNAME=postgres`, and `DB_DATABASE_NAME=immich`.
3. Restore the complete `UPLOAD_LOCATION`, not only its `library/` child. In this repository the variable points to `/srv/data/immich/library`, and that directory itself contains Immich's `upload/`, `library/`, `profile/`, `thumbs/`, `encoded-video/`, and `backups/` children.
4. If external libraries exist, recreate every bind mount with the same container path before starting Immich. A database path that is not mounted in the new container will appear missing.
5. Keep the DNS override in `immich-server` if the host's Docker DNS cannot resolve the Authentik issuer. Verify both public DNS and container reachability.
6. Configure the reverse proxy on a dedicated hostname root, not a URL subpath. Forward `Host`, `X-Real-IP`, `X-Forwarded-Proto`, and `X-Forwarded-For`; support WebSockets; disable request buffering; permit very large bodies; and use upload timeouts of at least 600 seconds.
7. Recreate GPU/NPU device mappings and matching Immich acceleration variants only after the CPU-based restored service works.

**OAuth settings in Immich**

In Administration → Settings → OAuth, verify:

- issuer URL matches the Authentik provider discovery URL;
- client ID and secret match Authentik;
- scope is `openid email profile`;
- signing algorithm is `RS256`;
- auto-register behavior is intentional;
- mobile redirect support includes `app.immich:///oauth-callback`;
- storage-label and role claims have not changed.

**Validation**

```bash
docker compose --project-directory compose/immich ps
docker logs --tail 100 immich_server
docker exec immich_postgres pg_isready -U postgres -d immich
docker exec immich_redis redis-cli ping
curl -I http://TARGET_IP:2283/
```

Compare user, asset, album, and shared-link counts. Open old and recent photos/videos, upload a new photo, download the original, test mobile OAuth, and inspect Administration → Job Queues. Do not delete the source assets until this succeeds.

### 8.3 Nextcloud

**Internal dependencies**

- MariaDB is authoritative for users, shares, file cache, app configuration, calendars, contacts, and metadata.
- `/srv/data/nextcloud/html` contains `config/`, custom apps, themes, and the default data directory; database and files are both required.
- Redis provides distributed cache and transactional file locking; its persisted cache is disposable.
- `nextcloud-cron` mounts the same `html` directory and runs `/cron.sh` for reliable background jobs.

**Required configuration**

1. Keep `nextcloud:33.0.0-apache` for the restore. `NEXTCLOUD_ADMIN_USER` and `NEXTCLOUD_ADMIN_PASSWORD` only bootstrap a fresh installation; they do not replace restored administrators.
2. Point the reverse proxy to `TARGET_IP:8080` and preserve large-upload/timeouts settings.
3. Inspect and update hostname/proxy settings only if the URL or proxy subnet changed:

```bash
docker exec -u www-data nextcloud_app php occ config:system:get trusted_domains
docker exec -u www-data nextcloud_app php occ config:system:get trusted_proxies
docker exec -u www-data nextcloud_app php occ config:system:get overwrite.cli.url
```

Add a new trusted-domain index without replacing an existing one:

```bash
docker exec -u www-data nextcloud_app php occ config:system:set trusted_domains NEXT_FREE_INDEX --value=cloud.example.com
docker exec -u www-data nextcloud_app php occ config:system:set overwriteprotocol --value=https
docker exec -u www-data nextcloud_app php occ config:system:set overwrite.cli.url --value=https://cloud.example.com
```

Set `trusted_proxies` to the actual reverse-proxy IP/subnet when required. Never trust an unnecessarily broad network.

4. Select cron background jobs:

```bash
docker exec -u www-data nextcloud_app php occ background:cron
```

5. Reconfigure SMTP and any external storage endpoints if their addresses changed.

**Validation**

```bash
docker compose --project-directory compose/nextcloud ps
docker exec -u www-data nextcloud_app php occ status
docker exec -u www-data nextcloud_app php occ maintenance:mode --off
docker exec nextcloud_db healthcheck.sh --connect --innodb_initialized
docker exec nextcloud_redis redis-cli ping
curl http://TARGET_IP:8080/status.php
```

Sign in, list/download/upload a file, test a share, verify installed apps, run `occ db:add-missing-indices` only if the Administration Overview recommends it, and confirm background jobs run via cron.

### 8.4 Vikunja

**Internal dependencies**

- PostgreSQL contains users, projects, tasks, labels, relations, and attachment metadata.
- `/srv/data/vikunja/files` contains attachments and other uploaded files.
- Database migrations run automatically when Vikunja starts.

**Required configuration**

1. Preserve `POSTGRES_PASSWORD` and `VIKUNJA_SERVICE_SECRET`.
2. Set `VIKUNJA_PUBLIC_URL` to the exact browser-facing HTTPS URL, including a trailing slash.
3. Ensure the files directory is writable by UID `1000`, the default user in the Vikunja image:

```bash
sudo chown -R 1000:1000 /srv/data/vikunja/files
```

4. Public registration is disabled. That is correct after restoring existing users; a fresh empty database would need a CLI-created user or temporarily enabled registration.
5. Point the reverse proxy to port `3456` and preserve forwarded host/protocol headers.
6. If password reset, reminders, or invitations by email are required, configure the `VIKUNJA_MAILER_*` environment variables documented for version 2.3 and test SMTP before relying on them.

**Validation**

```bash
docker compose --project-directory compose/vikunja ps
docker logs --tail 100 vikunja
docker exec vikunja-db pg_isready -U vikunja -d vikunja
docker exec vikunja /app/vikunja/vikunja doctor
curl -I http://TARGET_IP:3456/
```

Sign in, compare projects/tasks, open and upload an attachment, create a task, and confirm its persistence after a container restart.

### 8.5 Home Assistant

**Internal dependencies**

- This is Home Assistant Container, not Home Assistant OS or a supervised installation. Supervisor add-ons are not included.
- All application state lives under `/config`, including `.storage`, YAML, registries, tokens, and `home-assistant_v2.db`.
- `network_mode: host` is required for broad LAN discovery and makes Home Assistant listen directly on host port `8123`.
- `privileged: true` grants broad host/device access. Review this later, but do not tighten it during migration.

**Required configuration**

1. Preserve the entire config archive, including dot-directories and `secrets.yaml`.
2. Keep timezone and host time correct.
3. Reconnect USB radios using stable `/dev/serial/by-id/...` identities. If the target adapter or path differs, update the integration before expecting Zigbee/Z-Wave devices to work.
4. Reserve a stable LAN IP. Update integrations that point to the old server address, including MQTT broker settings if Mosquitto's address changes.
5. If using a reverse proxy, configure Home Assistant's `http:` section with `use_x_forwarded_for: true` and only the actual proxy address under `trusted_proxies`.
6. Recreate host-level Bluetooth/D-Bus/device access and firewall allowances needed by integrations.

**Validation**

```bash
docker compose --project-directory compose/homeassistant ps
docker logs --tail 200 homeassistant
curl -I http://TARGET_IP:8123/
```

Open Settings → System → Repairs and logs. Verify entities, dashboards, automations, history, MQTT entities, radios, Bluetooth, cameras, and notifications. Trigger one safe automation and confirm state/history survives a container restart.

### 8.6 Mosquitto MQTT

**Internal dependencies**

- `mosquitto.conf` enables persistence and two authenticated listeners: MQTT TCP `1883` and MQTT-over-WebSockets `9001`.
- `config/passwd` stores salted password hashes.
- `data/mosquitto.db` stores retained messages, subscriptions, and persistent sessions.
- Logs go to container stdout; the mounted log directory is currently not authoritative.

**Required configuration**

1. Preserve `config/passwd` or every MQTT client will need new credentials.
2. Keep `allow_anonymous false` on both listeners.
3. Do not expose plaintext `1883` or unencrypted `9001` to the public Internet. Use a VPN, private LAN, or configure Mosquitto TLS with certificates.
4. Ensure data is writable by the Mosquitto container (normally UID/GID `1883` in this image). A root restore preserves the archived numeric owner.
5. Update Home Assistant, sensors, Zigbee2MQTT, ESP devices, and MQTT Explorer if the broker hostname/IP changes.

For a new broker only, create the first user from `compose/mqtt`:

```bash
docker run --rm -it \
  -v "$(pwd)/config:/mosquitto/config" \
  eclipse-mosquitto:2 \
  mosquitto_passwd -c /mosquitto/config/passwd ha
chmod 644 config/passwd config/mosquitto.conf
```

Do not use `-c` when adding another user; it recreates and overwrites the password file.

**Validation**

Install `mosquitto-clients` on an admin machine and use the restored password:

```bash
mosquitto_sub -h TARGET_IP -p 1883 -u ha -P 'PASSWORD' -t 'migration/test' -C 1
```

In another terminal:

```bash
mosquitto_pub -h TARGET_IP -p 1883 -u ha -P 'PASSWORD' -t 'migration/test' -m 'ok'
```

Also check:

```bash
docker logs --tail 100 mosquitto
ss -lnt | grep -E ':(1883|9001) '
```

Confirm retained topics and Home Assistant MQTT entities reconnect. Avoid putting plaintext passwords in shell history; the inline examples are for a short controlled test.

## 9. Whole-system validation before DNS cutover

Run:

```bash
cd /opt/homelabCloud
./scripts/preflight.sh
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
docker compose --project-directory compose/authentik ps
docker compose --project-directory compose/immich ps
docker compose --project-directory compose/nextcloud ps
docker compose --project-directory compose/vikunja ps
docker compose --project-directory compose/homeassistant ps
docker compose --project-directory compose/mqtt ps
```

Then complete this checklist:

- [ ] all database healthchecks pass and no application logs show migration errors;
- [ ] all expected users and counts match the source inventory;
- [ ] Authentik password and TOTP login work;
- [ ] Immich local login, web OAuth, mobile OAuth, upload, view, and original download work;
- [ ] Nextcloud login, list, upload, download, sharing, apps, and cron work;
- [ ] Vikunja login, projects/tasks, create/edit, and attachments work;
- [ ] Home Assistant dashboards, history, automations, MQTT, radios, and devices work;
- [ ] MQTT publish/subscribe and retained messages work;
- [ ] reverse-proxy HTTPS certificates and WebSockets work for every hostname;
- [ ] SMTP test messages arrive where configured;
- [ ] external disks/libraries are mounted and visible;
- [ ] a target-side test backup completes and verifies successfully.

Test public hostnames before DNS cutover by using split DNS or an administrator workstation's hosts file. OIDC redirect URIs and TLS must use the real hostname, not only the target IP.

## 10. Cutover

1. Confirm the source is still stopped.
2. Change reverse-proxy upstreams and router/NAT destinations to the target.
3. Change DNS A/AAAA records to the target and verify resolution from LAN and an external network.
4. Clear local DNS caches only where necessary.
5. Repeat login and write tests through the public URLs.
6. Watch all logs during the first hour:

```bash
docker logs --since 10m authentik_server
docker logs --since 10m immich_server
docker logs --since 10m nextcloud_app
docker logs --since 10m vikunja
docker logs --since 10m homeassistant
docker logs --since 10m mosquitto
```

7. Keep the verified migration backup immutable and create a new backup from the target after validation.
8. Restore normal DNS TTL after the observation period.

## 11. Rollback

Rollback is safe only if the write boundary is respected.

1. Stop all target services:

```bash
sudo ./scripts/down.sh all
```

2. Point DNS, reverse proxy, and router rules back to the source.
3. Start the source:

```bash
sudo ./scripts/up.sh all
```

4. Validate source services.

If users wrote data to the target after cutover, do not blindly start the old source. Decide which server is authoritative and perform a new controlled export/import; there is no automatic merge for these application databases.

## 12. After migration

### Backups

Run a small database/config backup regularly and a full backup on a schedule appropriate for the data-change rate:

```bash
sudo ./scripts/backup.sh all --output /mnt/backup/homelab
sudo ./scripts/backup.sh all --full --output /mnt/backup/homelab
```

Maintain at least three copies, on two media types, with one off-site. Encrypt backups, restrict access, monitor free space, keep retention, and test restore on an isolated host. A successful command is not proof of recoverability; checksum verification and periodic restore tests are required.

### Upgrades

Only after the migration is stable:

1. create and verify a full backup;
2. read every release note between the pinned and target version;
3. update one application stack at a time;
4. never skip required Authentik major-version steps or downgrade Authentik;
5. keep database major upgrades separate from application upgrades;
6. validate and back up again after each stack.

The pinned Authentik release uses the repository's existing `/media` mount. Current Authentik releases use `/data`; change that layout only as part of a reviewed Authentik upgrade, not during the server move.

## 13. Official references

- [Docker Engine installation for Debian](https://docs.docker.com/engine/install/debian/)
- [Docker Compose plugin installation](https://docs.docker.com/compose/install/linux/)
- [Authentik backup and restore](https://docs.goauthentik.io/sys-mgmt/ops/backup-restore)
- [Authentik Docker Compose installation](https://docs.goauthentik.io/install-config/install/docker-compose/)
- [Authentik architecture](https://docs.goauthentik.io/core/architecture)
- [Immich backup and restore](https://docs.immich.app/administration/backup-and-restore/)
- [Immich OAuth](https://docs.immich.app/administration/oauth/)
- [Immich reverse proxy](https://docs.immich.app/administration/reverse-proxy/)
- [Nextcloud backup](https://docs.nextcloud.com/server/33/admin_manual/maintenance/backup.html)
- [Nextcloud restore](https://docs.nextcloud.com/server/33/admin_manual/maintenance/restore.html)
- [Vikunja backup requirements](https://vikunja.io/docs/what-to-backup/)
- [Vikunja Docker example and permissions](https://vikunja.io/docs/full-docker-example/)
- [Vikunja CLI and doctor](https://vikunja.io/docs/cli/)
- [Home Assistant Container on Linux](https://www.home-assistant.io/installation/linux)
- [Mosquitto configuration reference](https://mosquitto.org/man/mosquitto-conf-5.html)
