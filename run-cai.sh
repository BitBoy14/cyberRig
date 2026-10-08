#!/usr/bin/env bash
# run-cai.sh — starter CAI-harnesset pekt mot din lokale vLLM.
set -euo pipefail
set -a; source "$HOME/.env"; set +a

if ! curl -s -H "Authorization: Bearer ${OPENAI_API_KEY}" \
     "${OPENAI_API_BASE}/models" >/dev/null 2>&1; then
  echo "FEIL: når ikke vLLM på ${OPENAI_API_BASE}. Kjør ./serve.sh først."
  exit 1
fi

echo "==> Starter CAI mot ${CAI_MODEL} ..."
# CAI leser OPENAI_API_BASE / OPENAI_API_KEY / CAI_MODEL fra miljøet (.env)
exec cai
