#!/usr/bin/env bash
# serve.sh — starter vLLM i en tmux-sesjon slik at den overlever utlogging.
# Kjør ./bootstrap.sh først.
set -euo pipefail
set -a; source "$HOME/.env"; set +a

PORT="${PORT:-8000}"
TOOL_PARSER="${TOOL_PARSER:-hermes}"
MAX_LEN="${MAX_MODEL_LEN:-32768}"
TP_SIZE="${TP_SIZE:-1}"
GPU_UTIL="${GPU_UTIL:-0.90}"

if tmux has-session -t vllm 2>/dev/null; then
  echo "vLLM kjører allerede (tmux 'vllm'). Logg: tmux attach -t vllm"
  exit 0
fi

echo "==> Starter vLLM i tmux-sesjon 'vllm' (port $PORT, $TP_SIZE kort)..."
tmux new-session -d -s vllm "
  vllm serve '${MODEL_ID}' \
    --host 0.0.0.0 --port ${PORT} \
    --api-key '${OPENAI_API_KEY}' \
    --tensor-parallel-size ${TP_SIZE} \
    --gpu-memory-utilization ${GPU_UTIL} \
    --enable-auto-tool-choice \
    --tool-call-parser ${TOOL_PARSER} \
    --max-model-len ${MAX_LEN} \
    2>&1 | tee \$HOME/vllm.log
"

echo "==> Venter på at API-et blir klart (første last kan ta noen min)..."
until curl -s -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; do
  sleep 5; printf "."
done
echo ""
echo "==> vLLM er oppe:  http://localhost:${PORT}/v1"
echo "    Følg loggen:   tmux attach -t vllm   (Ctrl-b d for å koble fra)"
echo "    Stopp:         tmux kill-session -t vllm"
