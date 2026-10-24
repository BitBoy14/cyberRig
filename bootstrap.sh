#!/usr/bin/env bash
# bootstrap.sh — installerer alt på en fersk Vast-instans (vLLM-image).
# KJØR ./preflight.sh FØRST. Hvert steg er isolert: feiler CAI, står
# vLLM-kjernen likevel. Idempotent — trygt å kjøre flere ganger.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
[ -f ./config.env ] && { set -a; source ./config.env; set +a; }

MODEL_ID="${MODEL_ID:-philbert440/Qwen3.6-27B-Uncensored-Cyber}"
TOOL_PARSER="${TOOL_PARSER:-qwen3_coder}"
MAX_LEN="${MAX_MODEL_LEN:-131072}"
LONG_CONTEXT="${LONG_CONTEXT:-1}"
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}"
PORT="${PORT:-8001}"                 # 8001: 8000 er opptatt av Vast sin caddy
TP_SIZE="${TP_SIZE:-1}"
GPU_UTIL="${GPU_UTIL:-0.85}"
API_KEY="${API_KEY:-$(openssl rand -hex 16)}"
MODEL_DIR="${MODEL_DIR:-$HOME/models}"
LOG="$HOME/bootstrap.log"
: > "$LOG"

printf "${C_BOLD}${C_CYA}=== BOOTSTRAP ===${C_RESET}\n"
info "Modell:      $MODEL_ID"
info "Port:        $PORT   |  Parser: $TOOL_PARSER  |  Kort: $TP_SIZE"
info "Kontekst:    $MAX_LEN  |  YaRN: $LONG_CONTEXT  |  KV: $KV_CACHE_DTYPE"
info "Full logg:   $LOG"

# --- 1. Systempakker ---------------------------------------------------
step "Systempakker (git, git-lfs, tmux, curl, jq)"
export DEBIAN_FRONTEND=noninteractive
run_quiet "apt-get update"  "$LOG" -- apt-get update -qq || warn "apt update ga feil (ofte ufarlig)"
run_quiet "installerer"     "$LOG" -- apt-get install -y -qq git git-lfs tmux curl jq openssl lsof psmisc \
  || die "Klarte ikke installere systempakker."
git lfs install --skip-repo >>"$LOG" 2>&1 || true
ok "Systempakker klare"

# --- 2. vLLM / torch: IKKE rør hvis de finnes --------------------------
# Lærdom: 'pip install -U vllm' på et vLLM-image trigger xformers-bygging
# som feiler (manglende torch i build-env). Sjekk først, hopp over hvis OK.
step "Sjekker vLLM + torch (skal allerede finnes på vLLM-imaget)"
if python -c "import vllm, torch" >>"$LOG" 2>&1; then
  VLLM_V=$(python -c "import vllm; print(vllm.__version__)" 2>/dev/null)
  TORCH_V=$(python -c "import torch; print(torch.__version__)" 2>/dev/null)
  ok "vLLM $VLLM_V / torch $TORCH_V finnes — rører dem ikke"
else
  warn "vLLM/torch mangler — du er trolig IKKE på et vLLM-image."
  warn "Installerer vLLM (kan ta lang tid og feile på feil image)..."
  run_quiet "pip install vllm" "$LOG" -- pip install -q vllm \
    || die "vLLM-install feilet. Velg et vLLM-image på Vast neste gang."
  ok "vLLM installert"
fi

# --- 3. huggingface_hub: pin, IKKE -U ----------------------------------
# Lærdom: '-U huggingface_hub' drar til 2.x som bryter transformers/tokenizers.
step "Hugging Face CLI (pinnet til <2.0 for kompatibilitet)"
if hf --help >/dev/null 2>&1 && python -c "import huggingface_hub as h; exit(0 if int(h.__version__.split('.')[0])<2 else 1)" 2>/dev/null; then
  ok "hf finnes i kompatibel versjon"
else
  run_quiet "installerer hf" "$LOG" -- pip install -q "huggingface_hub>=1.5.0,<2.0" \
    || die "Klarte ikke installere huggingface_hub."
  ok "hf klar"
fi

# Valgfri HF-token (raskere/garantert nedlasting)
if [ -n "${HF_TOKEN:-}" ]; then
  hf auth login --token "$HF_TOKEN" >>"$LOG" 2>&1 && ok "Logget inn på HF" || warn "HF-login feilet (fortsetter)"
fi

# --- 4. Last ned modellen ----------------------------------------------
step "Laster ned modell (~55 GB — dette tar tid)"
mkdir -p "$MODEL_DIR"
TARGET="$MODEL_DIR/$(basename "$MODEL_ID")"
if [ -d "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
  info "Finnes allerede i $TARGET — hopper over (slett mappa for ny nedlasting)"
  ok "Modell på plass"
else
  info "Fremdrift vises live under:"
  if hf download "$MODEL_ID" --local-dir "$TARGET"; then
    ok "Modell lastet ned"
  else
    die "Modell-nedlasting feilet. Sjekk repo-navnet og evt. HF_TOKEN i config.env."
  fi
fi

# --- 5. CAI i ISOLERT venv ---------------------------------------------
# Lærdom: CAI river fastapi/openai/mcp/starlette ut under vLLM hvis den
# installeres i samme miljø. Eget venv + mcp>=2.3 for at importen virker.
step "CAI-harness (isolert venv — rører ikke vLLM-miljøet)"
CAI_VENV="$HOME/cai-venv"
if [ -x "$CAI_VENV/bin/cai" ] && "$CAI_VENV/bin/python" -c "import cai" >>"$LOG" 2>&1; then
  ok "CAI finnes allerede i $CAI_VENV"
else
  run_quiet "lager venv"        "$LOG" -- python3 -m venv "$CAI_VENV" || warn "venv-opprettelse ga feil"
  run_quiet "oppgraderer pip"   "$LOG" -- "$CAI_VENV/bin/pip" install -q -U pip || true
  if run_quiet "installerer cai-framework" "$LOG" -- "$CAI_VENV/bin/pip" install -q cai-framework; then
    # CAI trenger nyere mcp enn den drar inn selv
    run_quiet "fikser mcp-versjon" "$LOG" -- "$CAI_VENV/bin/pip" install -q "mcp>=2.3.0" || true
    if "$CAI_VENV/bin/python" -c "import cai" >>"$LOG" 2>&1; then
      ok "CAI installert og importerer"
    else
      warn "CAI installert men importerer ikke rent — vLLM virker likevel."
      warn "Du kan bruke et annet harness (aider/openhands) mot API-et i mellomtiden."
    fi
  else
    warn "CAI-install feilet — hopper over. vLLM-kjernen er upåvirket."
  fi
fi

# --- 6. Skriv .env -----------------------------------------------------
step "Skriver ~/.env"
cat > "$HOME/.env" <<EOF
OPENAI_API_BASE=http://localhost:${PORT}/v1
OPENAI_BASE_URL=http://localhost:${PORT}/v1
OPENAI_API_KEY=${API_KEY}
CAI_MODEL=openai/${MODEL_ID}
MODEL_ID=${MODEL_ID}
TOOL_PARSER=${TOOL_PARSER}
MAX_MODEL_LEN=${MAX_LEN}
LONG_CONTEXT=${LONG_CONTEXT}
KV_CACHE_DTYPE=${KV_CACHE_DTYPE}
PORT=${PORT}
TP_SIZE=${TP_SIZE}
GPU_UTIL=${GPU_UTIL}
EOF
ok "~/.env skrevet"

echo ""
printf "${C_BOLD}${C_GRN}=== FERDIG ===${C_RESET}\n"
info "Start modell:   ./serve.sh"
info "Test:           ./smoke-test.sh"
info "Harness:        ./run-cai.sh"
printf "    ${C_BOLD}API-nøkkel:${C_RESET}     %s\n" "$API_KEY"

