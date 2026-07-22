#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Create a portable homelab backup.

Usage:
  ./scripts/backup.sh [service|all] [--full] [--output DIR] [--dry-run]

Options:
  --full        Include large user data (required for a complete migration).
  --output DIR  Store the timestamped backup below DIR.
  --dry-run     Show containers and paths without writing or stopping anything.
  -h, --help    Show this help.

Examples:
  ./scripts/backup.sh authentik --full
  ./scripts/backup.sh all --full --output /mnt/backup/homelab
  ./scripts/backup.sh all --full --dry-run
EOF
}

backup_scope="all"
full_backup=0
dry_run=0
output_root="${BACKUP_ROOT:-${HOME}/backups/homelab}"
timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    all)
      backup_scope="all"
      shift
      ;;
    --full)
      full_backup=1
      shift
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a directory"
      output_root="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if is_service "$1"; then
        backup_scope="$1"
        shift
      else
        usage >&2
        die "Unknown argument: $1"
      fi
      ;;
  esac
done

if [[ "${backup_scope}" == "all" ]]; then
  selected_services=("${HOMELAB_SERVICES[@]}")
else
  selected_services=("${backup_scope}")
fi

destination="${output_root}/${backup_scope}_${timestamp}"
declare -a stopped_containers=()
nextcloud_maintenance=0

restart_stopped_containers() {
  local container
  if (( ${#stopped_containers[@]} > 0 )); then
    for container in "${stopped_containers[@]}"; do
      info "Restarting ${container}"
      docker start "${container}" >/dev/null || warn "Could not restart ${container}"
    done
    stopped_containers=()
  fi
}

disable_nextcloud_maintenance() {
  if (( nextcloud_maintenance == 1 )); then
    info "Disabling Nextcloud maintenance mode"
    docker exec -u www-data nextcloud_app php occ maintenance:mode --off >/dev/null \
      || warn "Could not disable Nextcloud maintenance mode"
    nextcloud_maintenance=0
  fi
}

cleanup() {
  local exit_code=$?
  disable_nextcloud_maintenance
  restart_stopped_containers
  if (( exit_code != 0 )) && [[ -d "${destination}" ]]; then
    printf 'Backup failed with exit code %d. Do not restore from this directory.\n' "${exit_code}" \
      > "${destination}/INCOMPLETE"
  fi
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

require_running_container() {
  container_is_running "$1" || die "Required container is not running: $1"
}

stop_if_running() {
  local container="$1"
  if container_is_running "${container}"; then
    info "Stopping ${container} for a consistent filesystem snapshot"
    docker stop --time 60 "${container}" >/dev/null
    stopped_containers+=("${container}")
  fi
}

copy_if_present() {
  local source="$1"
  local target="$2"
  if [[ -e "${source}" ]]; then
    mkdir -p "$(dirname "${target}")"
    cp -a "${source}" "${target}"
  fi
}

copy_service_config() {
  local service="$1"
  local source_dir
  local target_dir
  source_dir="$(compose_dir "${service}")"
  target_dir="${destination}/config/${service}"
  mkdir -p "${target_dir}"

  copy_if_present "$(compose_file "${service}")" "${target_dir}/$(basename "$(compose_file "${service}")")"
  copy_if_present "${source_dir}/.env" "${target_dir}/.env"
  copy_if_present "${source_dir}/.env.example" "${target_dir}/.env.example"

  if [[ "${service}" == "mqtt" ]]; then
    copy_if_present "$(persistent_path mqtt config)/mosquitto.conf" "${target_dir}/config/mosquitto.conf"
    copy_if_present "$(persistent_path mqtt config)/passwd" "${target_dir}/config/passwd"
  fi
}

archive_contents() {
  local source="$1"
  local archive_name="$2"
  local partial="${destination}/archives/${archive_name}.tar.gz.partial"

  if [[ ! -d "${source}" ]]; then
    warn "Skipping missing directory: ${source}"
    return 0
  fi

  info "Archiving ${source}"
  tar --numeric-owner -C "${source}" -czf "${partial}" .
  mv "${partial}" "${destination}/archives/${archive_name}.tar.gz"
}

dump_postgres() {
  local container="$1"
  local dump_name="$2"
  local partial="${destination}/dumps/${dump_name}.sql.gz.partial"

  require_running_container "${container}"
  info "Dumping PostgreSQL from ${container}"
  docker exec "${container}" sh -ec \
    'exec pg_dump --clean --if-exists --no-owner --no-privileges --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' \
    | gzip -c > "${partial}"
  mv "${partial}" "${destination}/dumps/${dump_name}.sql.gz"
}

dump_mariadb() {
  local container="$1"
  local dump_name="$2"
  local partial="${destination}/dumps/${dump_name}.sql.gz.partial"

  require_running_container "${container}"
  info "Dumping MariaDB from ${container}"
  docker exec "${container}" sh -ec \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mariadb-dump --single-transaction --quick --default-character-set=utf8mb4 --user=root "$MYSQL_DATABASE"' \
    | gzip -c > "${partial}"
  mv "${partial}" "${destination}/dumps/${dump_name}.sql.gz"
}

backup_authentik() {
  local data_root
  data_root="$(persistent_path authentik root)"
  copy_service_config authentik

  if (( full_backup == 1 )); then
    stop_if_running authentik_server
    stop_if_running authentik_worker
  fi
  dump_postgres authentik_postgres authentik
  archive_contents "${data_root}/media" authentik-media
  archive_contents "${data_root}/custom-templates" authentik-custom-templates
  archive_contents "${data_root}/certs" authentik-certs
  restart_stopped_containers
}

backup_immich() {
  copy_service_config immich
  if (( full_backup == 1 )); then
    stop_if_running immich_server
  fi
  dump_postgres immich_postgres immich
  if (( full_backup == 1 )); then
    archive_contents "$(persistent_path immich uploads)" immich-uploads
  fi
  restart_stopped_containers
}

backup_nextcloud() {
  local data_root
  data_root="$(persistent_path nextcloud root)"
  copy_service_config nextcloud

  if (( full_backup == 1 )); then
    require_running_container nextcloud_app
    info "Enabling Nextcloud maintenance mode"
    docker exec -u www-data nextcloud_app php occ maintenance:mode --on >/dev/null
    nextcloud_maintenance=1
  fi
  dump_mariadb nextcloud_db nextcloud
  if (( full_backup == 1 )); then
    archive_contents "${data_root}/html" nextcloud-html
  else
    archive_contents "${data_root}/html/config" nextcloud-config
  fi
  disable_nextcloud_maintenance
}

backup_vikunja() {
  local data_root
  data_root="$(persistent_path vikunja root)"
  copy_service_config vikunja
  if (( full_backup == 1 )); then
    stop_if_running vikunja
  fi
  dump_postgres vikunja-db vikunja
  if (( full_backup == 1 )); then
    archive_contents "${data_root}/files" vikunja-files
  fi
  restart_stopped_containers
}

backup_homeassistant() {
  copy_service_config homeassistant
  stop_if_running homeassistant
  archive_contents "$(persistent_path homeassistant config)" homeassistant-config
  restart_stopped_containers
}

backup_mqtt() {
  copy_service_config mqtt
  if (( full_backup == 1 )); then
    stop_if_running mosquitto
  fi
  archive_contents "$(persistent_path mqtt config)" mqtt-config
  if (( full_backup == 1 )); then
    archive_contents "$(persistent_path mqtt data)" mqtt-data
  fi
  restart_stopped_containers
}

show_dry_run() {
  local service
  local container
  local path
  local -a paths=()

  echo "Backup scope: ${backup_scope}"
  echo "Full backup: ${full_backup}"
  echo "Destination: ${destination}"
  echo

  for service in "${selected_services[@]}"; do
    echo "[${service}]"
    case "${service}" in
      authentik)
        containers=(authentik_server authentik_worker authentik_postgres authentik_redis)
        paths=("$(persistent_path authentik root)")
        ;;
      immich)
        containers=(immich_server immich_machine_learning immich_postgres immich_redis)
        paths=("$(persistent_path immich uploads)" "$(persistent_path immich database)")
        ;;
      nextcloud)
        containers=(nextcloud_app nextcloud_db nextcloud_redis)
        paths=("$(persistent_path nextcloud root)")
        ;;
      vikunja)
        containers=(vikunja vikunja-db)
        paths=("$(persistent_path vikunja root)")
        ;;
      homeassistant)
        containers=(homeassistant)
        paths=("$(persistent_path homeassistant config)")
        ;;
      mqtt)
        containers=(mosquitto)
        paths=("$(persistent_path mqtt config)" "$(persistent_path mqtt data)")
        ;;
    esac

    for container in "${containers[@]}"; do
      if container_is_running "${container}"; then
        printf '  container: %-28s running\n' "${container}"
      else
        printf '  container: %-28s not running\n' "${container}"
      fi
    done
    for path in "${paths[@]}"; do
      if [[ -e "${path}" ]]; then
        size="$(du -sh "${path}" 2>/dev/null | cut -f1 || true)"
        if [[ -n "${size}" ]]; then
          printf '  data: %-8s %s\n' "${size}" "${path}"
        else
          printf '  data: unreadable %s\n' "${path}"
        fi
      else
        printf '  data: missing %s\n' "${path}"
      fi
    done
    echo
  done
}

write_metadata() {
  local git_commit="unknown"
  git_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || true)"

  cat > "${destination}/meta/manifest.env" <<EOF
BACKUP_FORMAT_VERSION=1
BACKUP_SCOPE=${backup_scope}
FULL_BACKUP=${full_backup}
CREATED_AT=${timestamp}
SOURCE_HOST=$(hostname)
SOURCE_ARCH=$(uname -m)
GIT_COMMIT=${git_commit}
EOF

  git -C "${REPO_ROOT}" status --short > "${destination}/meta/git-status.txt" 2>/dev/null || true
  git -C "${REPO_ROOT}" diff --binary HEAD > "${destination}/meta/worktree.patch" 2>/dev/null || true
  git -C "${REPO_ROOT}" bundle create "${destination}/meta/repository.bundle" --all 2>/dev/null \
    || warn "Could not create the Git repository bundle"

  docker ps --no-trunc --format '{{.Names}}\t{{.Image}}\t{{.ID}}\t{{.Status}}' \
    | sort > "${destination}/meta/running-containers.tsv"
  docker version > "${destination}/meta/docker-version.txt"
  docker compose version > "${destination}/meta/docker-compose-version.txt"
}

write_checksums() {
  info "Calculating SHA-256 checksums"
  (
    cd "${destination}"
    find . -type f ! -name SHA256SUMS -print0 \
      | sort -z \
      | xargs -0 sha256sum > SHA256SUMS
  )
}

require_command docker
require_command gzip
require_command sha256sum
require_command tar
require_command realpath

if (( dry_run == 1 )); then
  show_dry_run
  exit 0
fi

[[ ! -e "${destination}" ]] || die "Backup destination already exists: ${destination}"
mkdir -p "${destination}/config" "${destination}/dumps" "${destination}/archives" "${destination}/meta"

write_metadata

for service in "${selected_services[@]}"; do
  info "Backing up ${service}"
  "backup_${service}"
done

cat > "${destination}/RESTORE.txt" <<EOF
This backup contains secrets and private user data. Keep it encrypted at rest.

Restore with the same repository revision whenever possible:
  ${REPO_ROOT}/scripts/restore.sh ${destination} ${backup_scope} --confirm

Read docs/MIGRATION_GUIDE.md before restoring on another server.
EOF
touch "${destination}/meta/COMPLETE"
write_checksums

trap - EXIT INT TERM
info "Backup complete: ${destination}"
