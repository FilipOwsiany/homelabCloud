#!/usr/bin/env bash

# Shared helpers for the homelab lifecycle and migration scripts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SCRIPT_DIR REPO_ROOT

readonly -a HOMELAB_SERVICES=(
  authentik
  immich
  nextcloud
  vikunja
  homeassistant
  mqtt
)

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARNING: $*" >&2
}

info() {
  echo "==> $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is not installed: $1"
}

is_service() {
  local candidate="$1"
  local known
  for known in "${HOMELAB_SERVICES[@]}"; do
    [[ "${candidate}" == "${known}" ]] && return 0
  done
  return 1
}

compose_dir() {
  printf '%s/compose/%s\n' "${REPO_ROOT}" "$1"
}

compose_file() {
  local service="$1"
  if [[ "${service}" == "homeassistant" ]]; then
    printf '%s/compose.yaml\n' "$(compose_dir "${service}")"
  else
    printf '%s/docker-compose.yml\n' "$(compose_dir "${service}")"
  fi
}

run_compose() {
  local service="$1"
  shift
  docker compose \
    --project-directory "$(compose_dir "${service}")" \
    --file "$(compose_file "${service}")" \
    "$@"
}

env_value() {
  local service="$1"
  local key="$2"
  local fallback="$3"
  local env_file
  local value

  env_file="$(compose_dir "${service}")/.env"
  value=""
  if [[ -f "${env_file}" ]]; then
    value="$(sed -n "s/^${key}=//p" "${env_file}" | tail -n 1)"
    value="${value%$'\r'}"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
  fi

  printf '%s\n' "${value:-${fallback}}"
}

absolute_service_path() {
  local service="$1"
  local path="$2"
  if [[ "${path}" == /* ]]; then
    printf '%s\n' "${path}"
  else
    realpath -m "$(compose_dir "${service}")/${path}"
  fi
}

persistent_path() {
  local service="$1"
  local kind="$2"
  local root

  case "${service}:${kind}" in
    authentik:root)
      env_value authentik AUTHENTIK_DATA_ROOT /srv/data/authentik
      ;;
    immich:uploads)
      env_value immich UPLOAD_LOCATION /srv/data/immich/library
      ;;
    immich:database)
      env_value immich DB_DATA_LOCATION /srv/data/immich/postgres
      ;;
    nextcloud:root)
      env_value nextcloud NEXTCLOUD_DATA_ROOT /srv/data/nextcloud
      ;;
    vikunja:root)
      env_value vikunja VIKUNJA_DATA_ROOT /srv/data/vikunja
      ;;
    homeassistant:config)
      root="$(env_value homeassistant HOMEASSISTANT_CONFIG_PATH ./config)"
      absolute_service_path homeassistant "${root}"
      ;;
    mqtt:config)
      root="$(env_value mqtt MQTT_CONFIG_PATH ./config)"
      absolute_service_path mqtt "${root}"
      ;;
    mqtt:data)
      root="$(env_value mqtt MQTT_DATA_PATH ./data)"
      absolute_service_path mqtt "${root}"
      ;;
    mqtt:log)
      root="$(env_value mqtt MQTT_LOG_PATH ./log)"
      absolute_service_path mqtt "${root}"
      ;;
    *)
      die "Unknown persistent path: ${service}:${kind}"
      ;;
  esac
}

container_is_running() {
  [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

wait_for_healthy_container() {
  local container="$1"
  local timeout_seconds="${2:-120}"
  local elapsed=0
  local state

  while (( elapsed < timeout_seconds )); do
    state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container}" 2>/dev/null || true)"
    case "${state}" in
      healthy|running)
        return 0
        ;;
      exited|dead|unhealthy)
        die "Container ${container} entered state: ${state}"
        ;;
    esac
    sleep 2
    ((elapsed += 2))
  done

  die "Timed out waiting for ${container} to become ready"
}
