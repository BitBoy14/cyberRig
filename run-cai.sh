#!/usr/bin/env bash
# run-cai.sh — starter CAI-harnesset (isolert venv) pekt mot din vLLM.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
[ -f "$HOME/.env" ] && { set -a; source "$HOME/.env"; set +a; }

CAI_VENV="$HOME/cai-venv"
BASE="${OPENAI_API_BASE:-http://localhost:8001/v1}"

if [ ! -x "$CAI_VENV/bin/cai" ]; then
  die "CAI ikke installert. Kjør ./bootstrap.sh (CAI-steget), eller bruk et annet harness mot $BASE."
fi

if ! curl -s -H "Authorization: Bearer ${OPENAI_API_KEY:-test123}" "$BASE/models" >/dev/null 2>&1; then
  die "Når ikke vLLM på $BASE. Kjør ./serve.sh først."
fi

info "Starter CAI mot ${CAI_MODEL:-$MODEL_ID} (API: $BASE)"
# CAI leser OPENAI_API_BASE / OPENAI_API_KEY / CAI_MODEL fra miljøet (.env)
exec "$CAI_VENV/bin/cai"
