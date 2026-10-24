#!/usr/bin/env bash
# serve.sh — rydder VRAM, starter vLLM i tmux, venter til API-et svarer.
# Lærdom: krasjede vLLM-starter etterlater zombie-prosesser som holder VRAM
# uten at nvidia-smi lister dem. Vi rydder med fuser før start.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
[ -f "$HOME/.env" ] && { set -a; source "$HOME/.env"; set +a; }

PORT="${PORT:-8001}"
TOOL_PARSER="${TOOL_PARSER:-qwen3_coder}"
MAX_LEN="${MAX_MODEL_LEN:-32768}"
TP_SIZE="${TP_SIZE:-1}"
GPU_UTIL="${GPU_UTIL:-0.85}"
API_KEY="${OPENAI_API_KEY:-test123}"

printf "${C_BOLD}${C_CYA}=== SERVE ===${C_RESET}\n"

# --- Allerede oppe? ----------------------------------------------------
if tmux has-session -t vllm 2>/dev/null; then
  if curl -s -H "Authorization: Bearer ${API_KEY}" "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; then
    ok "vLLM kjører allerede på port $PORT. (tmux attach -t vllm)"
    exit 0
  else
    warn "tmux-sesjon 'vllm' finnes men svarer ikke — rydder og starter på nytt."
    tmux kill-session -t vllm 2>/dev/null || true
  fi
fi

# --- Rydd VRAM ---------------------------------------------------------
# Lærdom 1: Vast sine vLLM-images starter sin EGEN vLLM via supervisor
# (tjenestene vllm/model-ui/ray, autorestart=true). Den legger beslag på
# 15-25 GB VRAM FØR cyberRig kjører, og pkill/fuser alene hjelper ikke —
# supervisor starter den bare opp igjen. Vi må stoppe tjenestene først.
# Rør IKKE caddy/instance_portal/tunnel_manager — det er Vast sin
# management-/auth-flate.
# Lærdom 2: krasjede vLLM-starter etterlater zombie-prosesser som holder
# VRAM uten at nvidia-smi lister dem. fuser rydder dem som fallback.
step "Rydder VRAM (stopper imagets egen vLLM-tjeneste først)"

# (a) Stopp supervisor-tjenestene så de ikke restartes (idempotent, trygt)
if command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl stop vllm model-ui ray 2>/dev/null || true
  info "Stoppet supervisor-tjenester (vllm, model-ui, ray)"
else
  info "supervisorctl ikke funnet — hopper over (trolig ikke et Vast vLLM-image)"
fi

# (b) Fallback: drep evt. zombie-prosesser som fortsatt holder kortet
pkill -9 -f "vllm serve"  2>/dev/null || true
pkill -9 -f "EngineCore"  2>/dev/null || true
fuser -k /dev/nvidia* 2>/dev/null || true

# (c) La kjernen frigjøre minnet
sleep 3

# (d) Verifiser at VRAM faktisk ble frigjort
read_vram
info "VRAM etter opprydding: $((VRAM_USED/1024)) GB brukt / $((VRAM_FREE/1024)) GB ledig"
if [ "$VRAM_USED" -gt 2048 ]; then
  warn "Fortsatt $((VRAM_USED/1024)) GB i bruk etter opprydding."
  warn "Slapp ikke image-tjenesten taket? Prøv manuelt: supervisorctl stop vllm"
  warn "Hvis dette ikke er din egen prosess, DELER du kortet — kjør ./preflight.sh."
fi

# --- Start -------------------------------------------------------------
step "Starter vLLM i tmux-sesjon 'vllm' (port $PORT, $TP_SIZE kort, util $GPU_UTIL)"
tmux new-session -d -s vllm "
  vllm serve '${MODEL_ID}' \
    --host 0.0.0.0 --port ${PORT} \
    --api-key '${API_KEY}' \
    --tensor-parallel-size ${TP_SIZE} \
    --gpu-memory-utilization ${GPU_UTIL} \
    --enable-auto-tool-choice \
    --tool-call-parser ${TOOL_PARSER} \
    --max-model-len ${MAX_LEN} \
    2>&1 | tee \$HOME/vllm.log
"
info "Logg strømmes til ~/vllm.log  (tmux attach -t vllm for live)"

# --- Vent, med timeout og feildeteksjon --------------------------------
step "Venter på at API-et blir klart"
info "Første oppstart tar typisk 1-3 min (vekter + CUDA-grafer)."
DEADLINE=$(( $(date +%s) + 600 ))   # 10 min tak
while :; do
  if curl -s -H "Authorization: Bearer ${API_KEY}" "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; then
    echo ""; ok "vLLM er oppe: http://localhost:${PORT}/v1"
    break
  fi
  # Død sesjon? Da er det en reell feil — vis den.
  if ! tmux has-session -t vllm 2>/dev/null; then
    echo ""
    warn "vLLM-prosessen døde under oppstart. Siste feil fra loggen:"
    grep -i -E "error|valueerror|runtimeerror|out of memory" "$HOME/vllm.log" | tail -15
    die "Oppstart feilet — se ~/vllm.log. Ved VRAM-feil: kjør ./preflight.sh."
  fi
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    echo ""; die "Timeout (10 min). Sjekk ~/vllm.log og tmux attach -t vllm."
  fi
  printf "."
  sleep 5
done

info "Følg loggen: tmux attach -t vllm   (Ctrl-b d for å koble fra)"
info "Stopp:       tmux kill-session -t vllm"
