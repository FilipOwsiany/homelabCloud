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

# Reverse startup order so consumers stop before their providers.
shutdown_order=(homeassistant vikunja immich nextcloud authentik mqtt)

if [[ "${target}" == "all" ]]; then
  for service in "${shutdown_order[@]}"; do
    info "Stopping ${service}"
    run_compose "${service}" down
  done
else
  info "Stopping ${target}"
  run_compose "${target}" down
fi
