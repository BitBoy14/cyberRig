#!/usr/bin/env bash
# bootstrap.sh — installs everything on a fresh Vast instance (vLLM image).
# RUN ./preflight.sh FIRST. Each step is isolated: if CAI fails, the vLLM
# core still stands. Idempotent — safe to run multiple times.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
[ -f ./config.env ] && { set -a; source ./config.env; set +a; }

MODEL_ID="${MODEL_ID:-philbert440/Qwen3.6-27B-Uncensored-Cyber}"
TOOL_PARSER="${TOOL_PARSER:-qwen3_coder}"
MAX_LEN="${MAX_MODEL_LEN:-131072}"
LONG_CONTEXT="${LONG_CONTEXT:-1}"
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-16}"
PORT="${PORT:-8001}"                 # 8001: 8000 is taken by Vast's caddy
TP_SIZE="${TP_SIZE:-1}"
GPU_UTIL="${GPU_UTIL:-0.85}"
API_KEY="${API_KEY:-$(openssl rand -hex 16)}"
MODEL_DIR="${MODEL_DIR:-$HOME/models}"
LOG="$HOME/bootstrap.log"
: > "$LOG"

printf "${C_BOLD}${C_CYA}=== BOOTSTRAP ===${C_RESET}\n"
info "Model:       $MODEL_ID"
info "Port:        $PORT   |  Parser: $TOOL_PARSER  |  Cards: $TP_SIZE"
info "Context:     $MAX_LEN  |  YaRN: $LONG_CONTEXT  |  KV: $KV_CACHE_DTYPE"
info "Full log:    $LOG"

# --- 1. System packages ------------------------------------------------
step "System packages (git, git-lfs, tmux, curl, jq)"
export DEBIAN_FRONTEND=noninteractive
run_quiet "apt-get update"  "$LOG" -- apt-get update -qq || warn "apt update returned an error (often harmless)"
run_quiet "installing"      "$LOG" -- apt-get install -y -qq git git-lfs tmux curl jq openssl lsof psmisc \
  || die "Could not install system packages."
git lfs install --skip-repo >>"$LOG" 2>&1 || true
ok "System packages ready"

# --- 2. Recon/pentest tooling (non-fatal) ------------------------------
# Supports recon/vuln-recon.sh: searchsploit (exploitdb) for public PoCs,
# whatweb + nmap for fingerprinting. Non-fatal: on an image where a package
# isn't in the repos, we warn and continue — the vLLM core is unaffected.
step "Recon tooling (exploitdb/searchsploit, whatweb, nmap)"
if run_quiet "installing recon tools" "$LOG" -- apt-get install -y -qq exploitdb whatweb nmap; then
  command -v searchsploit >/dev/null 2>&1 && searchsploit -u >>"$LOG" 2>&1 || true
  ok "Recon tooling ready"
else
  warn "Could not install all recon tools via apt (not in this image's repos?)."
  warn "vuln-recon.sh still works on CISA KEV + NVD (needs only curl + jq)."
  warn "searchsploit fallback: git clone https://gitlab.com/exploit-database/exploitdb"
fi

# --- 3. vLLM / torch: DON'T touch if present ---------------------------
# Lesson: 'pip install -U vllm' on a vLLM image triggers an xformers build
# that fails (torch missing in the build env). Check first, skip if OK.
step "Checking vLLM + torch (should already exist on the vLLM image)"
if python -c "import vllm, torch" >>"$LOG" 2>&1; then
  VLLM_V=$(python -c "import vllm; print(vllm.__version__)" 2>/dev/null)
  TORCH_V=$(python -c "import torch; print(torch.__version__)" 2>/dev/null)
  ok "vLLM $VLLM_V / torch $TORCH_V present — leaving them alone"
else
  warn "vLLM/torch missing — you are probably NOT on a vLLM image."
  warn "Installing vLLM (can take a long time and fail on the wrong image)..."
  run_quiet "pip install vllm" "$LOG" -- pip install -q vllm \
    || die "vLLM install failed. Pick a vLLM image on Vast next time."
  ok "vLLM installed"
fi

# --- 4. huggingface_hub: pin, DON'T -U ---------------------------------
# Lesson: '-U huggingface_hub' pulls 2.x which breaks transformers/tokenizers.
step "Hugging Face CLI (pinned to <2.0 for compatibility)"
if hf --help >/dev/null 2>&1 && python -c "import huggingface_hub as h; exit(0 if int(h.__version__.split('.')[0])<2 else 1)" 2>/dev/null; then
  ok "hf present in a compatible version"
else
  run_quiet "installing hf" "$LOG" -- pip install -q "huggingface_hub>=1.5.0,<2.0" \
    || die "Could not install huggingface_hub."
  ok "hf ready"
fi

# Optional HF token (faster/guaranteed download)
if [ -n "${HF_TOKEN:-}" ]; then
  hf auth login --token "$HF_TOKEN" >>"$LOG" 2>&1 && ok "Logged in to HF" || warn "HF login failed (continuing)"
fi

# --- 5. Download the model ---------------------------------------------
step "Downloading model (~55 GB — this takes a while)"
mkdir -p "$MODEL_DIR"
TARGET="$MODEL_DIR/$(basename "$MODEL_ID")"
if [ -d "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
  info "Already present in $TARGET — skipping (delete the dir for a fresh download)"
  ok "Model in place"
else
  info "Live progress below:"
  if hf download "$MODEL_ID" --local-dir "$TARGET"; then
    ok "Model downloaded"
  else
    die "Model download failed. Check the repo name and HF_TOKEN in config.env."
  fi
fi

# --- 6. CAI in an ISOLATED venv ----------------------------------------
# Lesson: CAI tears fastapi/openai/mcp/starlette out from under vLLM if it's
# installed in the same environment. Own venv + mcp>=2.3 so the import works.
step "CAI harness (isolated venv — doesn't touch the vLLM environment)"
CAI_VENV="$HOME/cai-venv"
if [ -x "$CAI_VENV/bin/cai" ] && "$CAI_VENV/bin/python" -c "import cai" >>"$LOG" 2>&1; then
  ok "CAI already present in $CAI_VENV"
else
  run_quiet "creating venv"     "$LOG" -- python3 -m venv "$CAI_VENV" || warn "venv creation returned an error"
  run_quiet "upgrading pip"     "$LOG" -- "$CAI_VENV/bin/pip" install -q -U pip || true
  if run_quiet "installing cai-framework" "$LOG" -- "$CAI_VENV/bin/pip" install -q cai-framework; then
    # CAI needs a newer mcp than it pulls in itself
    run_quiet "fixing mcp version" "$LOG" -- "$CAI_VENV/bin/pip" install -q "mcp>=2.3.0" || true
    if "$CAI_VENV/bin/python" -c "import cai" >>"$LOG" 2>&1; then
      ok "CAI installed and imports"
    else
      warn "CAI installed but doesn't import cleanly — vLLM works regardless."
      warn "You can use another harness (aider/openhands) against the API meanwhile."
    fi
  else
    warn "CAI install failed — skipping. The vLLM core is unaffected."
  fi
fi

# --- 7. Write .env -----------------------------------------------------
step "Writing ~/.env"
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
MAX_NUM_SEQS=${MAX_NUM_SEQS}
PORT=${PORT}
TP_SIZE=${TP_SIZE}
GPU_UTIL=${GPU_UTIL}
EOF
ok "~/.env written"

echo ""
printf "${C_BOLD}${C_GRN}=== DONE ===${C_RESET}\n"
info "Start model:    ./serve.sh"
info "Test:           ./smoke-test.sh"
info "Agent setup:    ./cai-agent/install.sh"
info "Harness:        ./run-cai.sh"
printf "    ${C_BOLD}API key:${C_RESET}       %s\n" "$API_KEY"
