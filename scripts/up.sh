#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  echo "Usage: $0 [service|all]"
}

target="${1:-all}"
[[ $# -le 1 ]] || { usage >&2; exit 2; }
[[ "${target}" == "all" ]] || is_service "${target}" || { usage >&2; exit 2; }

require_command docker

# Start providers before their consumers. MQTT is first because Home Assistant
# may connect to it during startup; authentik is before OAuth clients.
startup_order=(mqtt authentik nextcloud immich vikunja homeassistant)

if [[ "${target}" == "all" ]]; then
  for service in "${startup_order[@]}"; do
    info "Starting ${service}"
    run_compose "${service}" up -d
  done
else
  info "Starting ${target}"
  run_compose "${target}" up -d
fi
