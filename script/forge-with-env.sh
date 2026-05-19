#!/usr/bin/env bash
# Export repo `.env` into the environment, then exec a command (typically `forge`).
# `vm.env*` in Forge scripts reads the process environment; sourcing with `set -a`
# marks assignments as exported so the forge child inherits them (same as manual
# `set -a && source .env && set +a && forge ...`).
#
# Usage (from anywhere):
#   bash script/forge-with-env.sh forge script script/SignDelegationWithSafe.s.sol:SignDelegationWithSafe \
#     --sig "runOpenRootDelegation()" -vvv --rpc-url "$LINEA_RPC_URL"
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
else
  echo "forge-with-env: warning: no .env at ${ROOT}/.env" >&2
fi
exec "$@"
