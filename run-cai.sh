#!/usr/bin/env bash
# run-cai.sh — starts the CAI harness (isolated venv) pointed at your vLLM.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
[ -f "$HOME/.env" ] && { set -a; source "$HOME/.env"; set +a; }

CAI_VENV="$HOME/cai-venv"
BASE="${OPENAI_API_BASE:-http://localhost:8001/v1}"

if [ ! -x "$CAI_VENV/bin/cai" ]; then
  die "CAI not installed. Run ./bootstrap.sh (CAI step), or use another harness against $BASE."
fi

if ! curl -s -H "Authorization: Bearer ${OPENAI_API_KEY:-test123}" "$BASE/models" >/dev/null 2>&1; then
  die "Cannot reach vLLM at $BASE. Run ./serve.sh first."
fi

info "Starting CAI against ${CAI_MODEL:-$MODEL_ID} (API: $BASE)"
if [ -n "${CAI_AGENT_TYPE:-}" ]; then
  info "Default agent: $CAI_AGENT_TYPE"
else
  warn "No default agent set. Run ./cai-agent/install.sh to wire in the"
  warn "'known-holes-first' pentest agent, or pick one with /agent inside cai."
fi
# CAI reads OPENAI_API_BASE / OPENAI_API_KEY / CAI_MODEL / CAI_AGENT_TYPE from the
# environment (.env). CYBERRIG_HOME (set by cai-agent/install.sh) lets the agent
# find ./recon/vuln-recon.sh.
exec "$CAI_VENV/bin/cai"
