#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

failures=0
warnings=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; ((failures += 1)); }
notice() { printf 'WARN  %s\n' "$*" >&2; ((warnings += 1)); }

if command -v docker >/dev/null 2>&1; then
  pass "Docker CLI is installed: $(docker --version)"
else
  fail "Docker CLI is not installed"
fi

if docker compose version >/dev/null 2>&1; then
  pass "Docker Compose plugin is installed: $(docker compose version)"
else
  fail "Docker Compose plugin is not available"
fi

if docker info >/dev/null 2>&1; then
  pass "Docker daemon is reachable"
else
  fail "Docker daemon is not reachable by the current user"
fi

for service in "${HOMELAB_SERVICES[@]}"; do
  env_file="$(compose_dir "${service}")/.env"
  if [[ -f "${env_file}" ]] || [[ "${service}" == "mqtt" ]] || [[ "${service}" == "homeassistant" ]]; then
    pass "${service}: environment file requirement is satisfied"
  else
    fail "${service}: missing ${env_file}; copy .env.example to .env and edit it"
  fi

  if run_compose "${service}" config --quiet >/dev/null 2>&1; then
    pass "${service}: Compose configuration is valid"
  else
    fail "${service}: Compose configuration is invalid"
  fi
done

for item in \
  "authentik:$(persistent_path authentik root)" \
  "immich uploads:$(persistent_path immich uploads)" \
  "immich database:$(persistent_path immich database)" \
  "nextcloud:$(persistent_path nextcloud root)" \
  "vikunja:$(persistent_path vikunja root)" \
  "homeassistant:$(persistent_path homeassistant config)" \
  "mqtt config:$(persistent_path mqtt config)" \
  "mqtt data:$(persistent_path mqtt data)"; do
  label="${item%%:*}"
  path="${item#*:}"
  if [[ -d "${path}" ]]; then
    pass "${label}: persistent path exists (${path})"
    [[ -r "${path}" ]] || notice "${label}: path is not readable by the current user (${path})"
  else
    notice "${label}: persistent path does not exist yet (${path})"
  fi
done

printf '\nPreflight result: %d failure(s), %d warning(s).\n' "${failures}" "${warnings}"
(( failures == 0 ))
