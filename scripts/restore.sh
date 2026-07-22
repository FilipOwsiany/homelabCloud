#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Restore a backup created by scripts/backup.sh onto an empty target.

Usage:
  ./scripts/restore.sh BACKUP_DIR [service|all] [--confirm] [--keep-env] [--dry-run]

Options:
  --confirm   Acknowledge that selected stacks will be stopped and changed.
  --keep-env  Keep existing .env files instead of installing them from the backup.
  --dry-run   Verify the backup and show target paths without changing anything.
  -h, --help  Show this help.

The script never deletes existing data. It refuses to restore into non-empty
persistent directories. Move an existing installation aside before restoring.
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }

backup_dir=""
restore_scope="all"
confirmed=0
keep_env=0
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm)
      confirmed=1
      shift
      ;;
    --keep-env)
      keep_env=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    all)
      restore_scope="all"
      shift
      ;;
    *)
      if [[ -z "${backup_dir}" ]]; then
        backup_dir="$(realpath -m "$1")"
        shift
      elif is_service "$1"; then
        restore_scope="$1"
        shift
      else
        usage >&2
        die "Unknown argument: $1"
      fi
      ;;
  esac
done

[[ -n "${backup_dir}" ]] || die "A backup directory is required"
[[ -d "${backup_dir}" ]] || die "Backup directory does not exist: ${backup_dir}"
[[ -f "${backup_dir}/meta/COMPLETE" ]] || die "Backup is not marked complete"
[[ ! -e "${backup_dir}/INCOMPLETE" ]] || die "Backup is marked incomplete"
[[ -f "${backup_dir}/SHA256SUMS" ]] || die "Backup has no checksum manifest"
[[ -f "${backup_dir}/meta/manifest.env" ]] || die "Backup has no metadata manifest"

manifest_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "${backup_dir}/meta/manifest.env" | tail -n 1
}

backup_format="$(manifest_value BACKUP_FORMAT_VERSION)"
backup_scope="$(manifest_value BACKUP_SCOPE)"
backup_is_full="$(manifest_value FULL_BACKUP)"
[[ "${backup_format}" == "1" ]] || die "Unsupported backup format: ${backup_format}"
[[ "${backup_scope}" == "all" ]] || is_service "${backup_scope}" \
  || die "Invalid backup scope in manifest: ${backup_scope}"

if [[ "${backup_scope}" != "all" && "${restore_scope}" == "all" ]]; then
  restore_scope="${backup_scope}"
fi
if [[ "${backup_scope}" != "all" && "${restore_scope}" != "${backup_scope}" ]]; then
  die "Backup contains ${backup_scope}, not ${restore_scope}"
fi

if [[ "${restore_scope}" == "all" ]]; then
  selected_services=(mqtt authentik nextcloud immich vikunja homeassistant)
else
  selected_services=("${restore_scope}")
fi

for service in "${selected_services[@]}"; do
  case "${service}" in
    immich|nextcloud|vikunja|mqtt)
      [[ "${backup_is_full}" == "1" ]] \
        || die "${service} requires a --full backup for migration"
      ;;
  esac
done

require_command docker
require_command gzip
require_command realpath
require_command sed
require_command sha256sum
require_command tar

info "Verifying backup checksums"
(
  cd "${backup_dir}"
  sha256sum --check --quiet SHA256SUMS
) || die "Backup checksum verification failed"

install_file_without_overwrite() {
  local source="$1"
  local target="$2"
  local mode="${3:-600}"

  [[ -f "${source}" ]] || return 0
  if [[ -e "${target}" ]]; then
    cmp --silent "${source}" "${target}" \
      || die "Refusing to overwrite different file: ${target}. Move it aside or use --keep-env."
    return 0
  fi

  mkdir -p "$(dirname "${target}")"
  cp "${source}" "${target}"
  chmod "${mode}" "${target}"
  if (( EUID == 0 )); then
    chown --reference="$(dirname "${target}")" "${target}"
  fi
}

install_service_secrets() {
  local service="$1"
  local snapshot="${backup_dir}/config/${service}"
  local target="$(compose_dir "${service}")"

  if (( keep_env == 0 )); then
    install_file_without_overwrite "${snapshot}/.env" "${target}/.env" 600
  fi

  if [[ "${service}" == "mqtt" ]]; then
    install_file_without_overwrite \
      "${snapshot}/config/mosquitto.conf" \
      "$(persistent_path mqtt config)/mosquitto.conf" 644
    install_file_without_overwrite \
      "${snapshot}/config/passwd" \
      "$(persistent_path mqtt config)/passwd" 644
  fi
}

directory_is_empty() {
  local target="$1"
  [[ ! -d "${target}" ]] || [[ -z "$(find "${target}" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

require_empty_directory() {
  local target="$1"
  directory_is_empty "${target}" \
    || die "Refusing to overwrite non-empty persistent directory: ${target}"
}

require_backup_file() {
  [[ -f "$1" ]] || die "Required backup component is missing: $1"
}

precheck_service() {
  local service="$1"
  local root
  case "${service}" in
    authentik)
      root="$(persistent_path authentik root)"
      require_backup_file "${backup_dir}/dumps/authentik.sql.gz"
      require_empty_directory "${root}/database"
      require_empty_directory "${root}/redis"
      require_empty_directory "${root}/media"
      require_empty_directory "${root}/custom-templates"
      require_empty_directory "${root}/certs"
      ;;
    immich)
      require_backup_file "${backup_dir}/dumps/immich.sql.gz"
      require_backup_file "${backup_dir}/archives/immich-uploads.tar.gz"
      require_empty_directory "$(persistent_path immich database)"
      require_empty_directory "$(persistent_path immich uploads)"
      ;;
    nextcloud)
      root="$(persistent_path nextcloud root)"
      require_backup_file "${backup_dir}/dumps/nextcloud.sql.gz"
      require_backup_file "${backup_dir}/archives/nextcloud-html.tar.gz"
      require_empty_directory "${root}/db"
      require_empty_directory "${root}/redis"
      require_empty_directory "${root}/html"
      ;;
    vikunja)
      root="$(persistent_path vikunja root)"
      require_backup_file "${backup_dir}/dumps/vikunja.sql.gz"
      require_backup_file "${backup_dir}/archives/vikunja-files.tar.gz"
      require_empty_directory "${root}/db"
      require_empty_directory "${root}/files"
      ;;
    homeassistant)
      require_backup_file "${backup_dir}/archives/homeassistant-config.tar.gz"
      require_empty_directory "$(persistent_path homeassistant config)"
      ;;
    mqtt)
      require_backup_file "${backup_dir}/archives/mqtt-data.tar.gz"
      require_empty_directory "$(persistent_path mqtt data)"
      ;;
  esac
}

show_restore_plan() {
  local service="$1"
  local root
  case "${service}" in
    authentik)
      root="$(persistent_path authentik root)"
      printf '  database, Redis cache, media, templates, certificates -> %s\n' "${root}"
      ;;
    immich)
      printf '  database -> %s\n' "$(persistent_path immich database)"
      printf '  assets   -> %s\n' "$(persistent_path immich uploads)"
      ;;
    nextcloud)
      printf '  database, Redis cache, application and user files -> %s\n' "$(persistent_path nextcloud root)"
      ;;
    vikunja)
      printf '  database and attachments -> %s\n' "$(persistent_path vikunja root)"
      ;;
    homeassistant)
      printf '  configuration and SQLite state -> %s\n' "$(persistent_path homeassistant config)"
      ;;
    mqtt)
      printf '  broker configuration -> %s\n' "$(persistent_path mqtt config)"
      printf '  retained messages    -> %s\n' "$(persistent_path mqtt data)"
      ;;
  esac
}

echo "Backup: ${backup_dir}"
echo "Backup scope: ${backup_scope}; restore scope: ${restore_scope}; full: ${backup_is_full}"
echo "Targets:"
for service in "${selected_services[@]}"; do
  echo "[${service}]"
  show_restore_plan "${service}"
done

if (( dry_run == 1 )); then
  exit 0
fi
(( confirmed == 1 )) || die "Restore requires --confirm. Run with --dry-run first."

# Environment files determine target paths, so install them before checking that
# every destination is empty. Existing, different files are never overwritten.
for service in "${selected_services[@]}"; do
  install_service_secrets "${service}"
done
for service in "${selected_services[@]}"; do
  precheck_service "${service}"
done

extract_archive() {
  local archive="$1"
  local target="$2"
  [[ -f "${archive}" ]] || return 0
  mkdir -p "${target}"
  info "Restoring $(basename "${archive}") to ${target}"
  tar -xzf "${archive}" -C "${target}"
}

restore_postgres_dump() {
  local container="$1"
  local dump_file="$2"
  local immich_compatibility="${3:-0}"

  wait_for_healthy_container "${container}" 180
  info "Restoring PostgreSQL database in ${container}"
  if (( immich_compatibility == 1 )); then
    gzip -dc "${dump_file}" \
      | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
      | docker exec -i "${container}" sh -ec \
        'exec psql --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --single-transaction --set ON_ERROR_STOP=on'
  else
    gzip -dc "${dump_file}" \
      | docker exec -i "${container}" sh -ec \
        'exec psql --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --single-transaction --set ON_ERROR_STOP=on'
  fi
}

restore_authentik() {
  local root
  root="$(persistent_path authentik root)"
  extract_archive "${backup_dir}/archives/authentik-media.tar.gz" "${root}/media"
  extract_archive "${backup_dir}/archives/authentik-custom-templates.tar.gz" "${root}/custom-templates"
  extract_archive "${backup_dir}/archives/authentik-certs.tar.gz" "${root}/certs"
  run_compose authentik up -d authentik-postgres authentik-redis
  restore_postgres_dump authentik_postgres "${backup_dir}/dumps/authentik.sql.gz"
  run_compose authentik up -d
}

restore_immich() {
  extract_archive "${backup_dir}/archives/immich-uploads.tar.gz" "$(persistent_path immich uploads)"
  run_compose immich up -d database
  restore_postgres_dump immich_postgres "${backup_dir}/dumps/immich.sql.gz" 1
  run_compose immich up -d
}

restore_nextcloud() {
  local root
  local attempt
  local ready=0
  root="$(persistent_path nextcloud root)"
  extract_archive "${backup_dir}/archives/nextcloud-html.tar.gz" "${root}/html"
  run_compose nextcloud up -d nextcloud-db nextcloud-redis
  wait_for_healthy_container nextcloud_db 180
  info "Restoring MariaDB database in nextcloud_db"
  gzip -dc "${backup_dir}/dumps/nextcloud.sql.gz" \
    | docker exec -i nextcloud_db sh -ec \
      'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mariadb --user=root "$MYSQL_DATABASE"'
  run_compose nextcloud up -d
  for attempt in {1..60}; do
    if docker exec -u www-data nextcloud_app php occ status >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done
  (( ready == 1 )) || die "Nextcloud did not become ready after database restore"
  docker exec -u www-data nextcloud_app php occ maintenance:mode --off
  docker exec -u www-data nextcloud_app php occ maintenance:data-fingerprint
}

restore_vikunja() {
  local root
  root="$(persistent_path vikunja root)"
  extract_archive "${backup_dir}/archives/vikunja-files.tar.gz" "${root}/files"
  run_compose vikunja up -d vikunja-db
  restore_postgres_dump vikunja-db "${backup_dir}/dumps/vikunja.sql.gz"
  run_compose vikunja up -d
}

restore_homeassistant() {
  extract_archive "${backup_dir}/archives/homeassistant-config.tar.gz" "$(persistent_path homeassistant config)"
  run_compose homeassistant up -d
}

restore_mqtt() {
  extract_archive "${backup_dir}/archives/mqtt-data.tar.gz" "$(persistent_path mqtt data)"
  run_compose mqtt up -d
}

for service in "${selected_services[@]}"; do
  info "Stopping ${service} before restore"
  run_compose "${service}" down
done

for service in "${selected_services[@]}"; do
  info "Restoring ${service}"
  "restore_${service}"
done

info "Restore finished. Complete every validation item in docs/MIGRATION_GUIDE.md before changing DNS."
