#!/usr/bin/env bash
# serve.sh — clears VRAM, starts vLLM in tmux, waits until the API responds.
# Lesson: crashed vLLM starts leave zombie processes that hold VRAM without
# nvidia-smi listing them. We clear them with fuser before starting.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
[ -f "$HOME/.env" ] && { set -a; source "$HOME/.env"; set +a; }
# config.env (the user's tuning file) wins over ~/.env for knobs it defines,
# e.g. REASONING_PARSER / GEN_CONFIG_OVERRIDE / TP_SIZE.
[ -f ./config.env ] && { set -a; source ./config.env; set +a; }

PORT="${PORT:-8001}"
TOOL_PARSER="${TOOL_PARSER:-qwen3_coder}"
MAX_LEN="${MAX_MODEL_LEN:-131072}"
TP_SIZE="${TP_SIZE:-1}"
GPU_UTIL="${GPU_UTIL:-0.85}"
API_KEY="${OPENAI_API_KEY:-test123}"
LONG_CONTEXT="${LONG_CONTEXT:-1}"       # 1 = YaRN-scale from native to MAX_LEN
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}" # fp8 halves the KV cache (128k on one A100 80GB)
NATIVE_CTX="${NATIVE_CTX:-32768}"       # the model's native context (Qwen3 = 32768)
MAX_NUM_SEQS="${MAX_NUM_SEQS:-16}"      # Mamba hybrid: each sequence takes one Mamba cache
                                        # block. vLLM default (256) blows up at long
                                        # context; 16 is plenty for one agent
# Qwen3.6 reasons in "thinking" mode by default, wrapping it in <think>…</think>.
# Without a reasoning parser that text leaks into the message body (you'll see
# bare </think> in the agent output) and can corrupt tool calls. 'qwen3' splits
# reasoning from the answer. Set REASONING_PARSER="" to disable (e.g. if a future
# model doesn't emit think tags, or tool-calling misbehaves on your vLLM build).
REASONING_PARSER="${REASONING_PARSER-qwen3}"
# Default sampling as a JSON blob (vLLM --override-generation-config). Qwen3
# thinking mode wants temp≈0.6 top_p 0.95 top_k 20 — NOT greedy (temp 0 loops).
# The mild presence_penalty curbs the "go in circles" repetition. This sets the
# server-side default; CAI/clients can still override per request. Set empty to
# disable (or if your vLLM build rejects the flag as unrecognized).
# Default kept in its own var — a JSON literal inside ${VAR-…} trips bash brace
# parsing (leaks a stray }). With '-', an explicit empty value disables it.
_GEN_CONFIG_DEFAULT='{"temperature":0.6,"top_p":0.95,"top_k":20,"presence_penalty":0.5}'
GEN_CONFIG_OVERRIDE="${GEN_CONFIG_OVERRIDE-$_GEN_CONFIG_DEFAULT}"

printf "${C_BOLD}${C_CYA}=== SERVE ===${C_RESET}\n"

# --- Already up? -------------------------------------------------------
if tmux has-session -t vllm 2>/dev/null; then
  if curl -s -H "Authorization: Bearer ${API_KEY}" "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; then
    ok "vLLM already running on port $PORT. (tmux attach -t vllm)"
    exit 0
  else
    warn "tmux session 'vllm' exists but doesn't respond — clearing and restarting."
    tmux kill-session -t vllm 2>/dev/null || true
  fi
fi

# --- Clear VRAM --------------------------------------------------------
# Lesson 1: Vast's vLLM images start their OWN vLLM via supervisor
# (services vllm/model-ui/ray, autorestart=true). It claims 15-25 GB VRAM
# BEFORE cyberRig runs, and pkill/fuser alone don't help — supervisor just
# restarts it. We have to stop the services first. Do NOT touch
# caddy/instance_portal/tunnel_manager — that's Vast's management/auth layer.
# Lesson 2: crashed vLLM starts leave zombie processes that hold VRAM
# without nvidia-smi listing them. fuser clears them as a fallback.
step "Clearing VRAM (stopping the image's own vLLM service first)"

# (a) Stop the supervisor services so they aren't restarted (idempotent, safe)
if command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl stop vllm model-ui ray 2>/dev/null || true
  info "Stopped supervisor services (vllm, model-ui, ray)"
else
  info "supervisorctl not found — skipping (probably not a Vast vLLM image)"
fi

# (b) Fallback: kill any zombie processes still holding the card
pkill -9 -f "vllm serve"  2>/dev/null || true
pkill -9 -f "EngineCore"  2>/dev/null || true
fuser -k /dev/nvidia* 2>/dev/null || true

# (c) Let the kernel free the memory
sleep 3

# (d) Verify VRAM was actually freed
read_vram
info "VRAM after cleanup: $((VRAM_USED/1024)) GB used / $((VRAM_FREE/1024)) GB free"
if [ "$VRAM_USED" -gt 2048 ]; then
  warn "Still $((VRAM_USED/1024)) GB in use after cleanup."
  warn "Did the image service not let go? Try manually: supervisorctl stop vllm"
  warn "If this isn't your own process, you're SHARING the card — run ./preflight.sh."
fi

# --- Start -------------------------------------------------------------
step "Starting vLLM in tmux session 'vllm' (port $PORT, $TP_SIZE cards, util $GPU_UTIL)"

# Prefer the locally downloaded weights. bootstrap.sh downloads with --local-dir
# into $MODEL_DIR, which is NOT the HF cache — passing the bare repo id here would
# make vLLM re-download ~55 GB. When we serve from the local path we pin
# --served-model-name back to the repo id so the API name stays what clients and
# CAI expect (smoke-test.sh / run-cai.sh / CAI_MODEL in ~/.env all use $MODEL_ID).
MODEL_PATH="$MODEL_ID"
SERVED_NAME=""
LOCAL_DIR="${MODEL_DIR:-$HOME/models}/$(basename "$MODEL_ID")"
if [ -d "$LOCAL_DIR" ] && [ -n "$(ls -A "$LOCAL_DIR" 2>/dev/null)" ]; then
  MODEL_PATH="$LOCAL_DIR"; SERVED_NAME="$MODEL_ID"
  info "Serving local weights: $LOCAL_DIR  (API name: $MODEL_ID)"
else
  info "No local weights at $LOCAL_DIR — resolving '$MODEL_ID' from the HF cache/hub"
fi

# Build the vLLM command as an array — robust against special chars in the rope JSON.
CMD=( vllm serve "$MODEL_PATH"
  --host 0.0.0.0 --port "$PORT"
  --api-key "$API_KEY"
  --tensor-parallel-size "$TP_SIZE"
  --gpu-memory-utilization "$GPU_UTIL"
  --enable-auto-tool-choice
  --tool-call-parser "$TOOL_PARSER"
  --max-model-len "$MAX_LEN"
  --max-num-seqs "$MAX_NUM_SEQS" )
[ -n "$SERVED_NAME" ] && CMD+=( --served-model-name "$SERVED_NAME" )
# Reasoning (thinking) mode: split <think>…</think> from the answer so it doesn't
# leak into tool calls. Optional default sampling override.
[ -n "$REASONING_PARSER" ]   && CMD+=( --reasoning-parser "$REASONING_PARSER" )
[ -n "$GEN_CONFIG_OVERRIDE" ] && CMD+=( --override-generation-config "$GEN_CONFIG_OVERRIDE" )

# YaRN: stretch native context to MAX_LEN. factor = MAX_LEN / native.
# vLLM 0.11.1 removed the --rope-scaling / --rope-theta flags; the documented
# replacement is --hf-overrides under the rope_parameters key. We keep
# rope_theta explicit because a bare rope override can drop it and silently
# fall back to base 10000, wrecking long-context quality. Read it from the
# model's config.json if we can find it, else default to the Qwen3 base (1e6).
if [ "$LONG_CONTEXT" = "1" ] && [ "$MAX_LEN" -gt "$NATIVE_CTX" ]; then
  FACTOR=$(awk "BEGIN{printf \"%.2f\", $MAX_LEN/$NATIVE_CTX}")
  ROPE_THETA=$(jq -r '.rope_theta // .rope_parameters.rope_theta // empty' "$LOCAL_DIR/config.json" 2>/dev/null)
  ROPE_THETA="${ROPE_THETA:-1000000}"
  CMD+=( --hf-overrides "{\"rope_parameters\":{\"rope_type\":\"yarn\",\"factor\":$FACTOR,\"original_max_position_embeddings\":$NATIVE_CTX,\"rope_theta\":$ROPE_THETA}}" )
  info "YaRN on: $NATIVE_CTX -> $MAX_LEN tokens (factor $FACTOR, rope_theta $ROPE_THETA)"
fi
# fp8 KV cache halves the memory so long context fits on one A100 80GB.
[ "$KV_CACHE_DTYPE" != "auto" ] && CMD+=( --kv-cache-dtype "$KV_CACHE_DTYPE" )

# Write a launcher so the quoting (notably the JSON) survives into tmux.
LAUNCHER="$HOME/.cyberrig_vllm_launch.sh"
{ printf '#!/usr/bin/env bash\n'; printf '%q ' "${CMD[@]}"; printf '\n'; } > "$LAUNCHER"
chmod +x "$LAUNCHER"
info "Launch command: $LAUNCHER (cat to inspect)"
tmux new-session -d -s vllm "bash '$LAUNCHER' 2>&1 | tee \$HOME/vllm.log"
info "Log streams to ~/vllm.log  (tmux attach -t vllm for live)"

# --- Wait, with timeout and failure detection -------------------------
step "Waiting for the API to become ready"
info "First startup typically takes 1-3 min (weights + CUDA graphs)."
DEADLINE=$(( $(date +%s) + 600 ))   # 10 min cap
while :; do
  if curl -s -H "Authorization: Bearer ${API_KEY}" "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; then
    echo ""; ok "vLLM is up: http://localhost:${PORT}/v1"
    break
  fi
  # Dead session? Then it's a real failure — show it.
  if ! tmux has-session -t vllm 2>/dev/null; then
    echo ""
    warn "The vLLM process died during startup. Last error from the log:"
    grep -i -E "error|valueerror|runtimeerror|out of memory" "$HOME/vllm.log" | tail -15
    die "Startup failed — see ~/vllm.log. On a VRAM error: run ./preflight.sh."
  fi
  if [ "$(date +%s)" -gt "$DEADLINE" ]; then
    echo ""; die "Timeout (10 min). Check ~/vllm.log and tmux attach -t vllm."
  fi
  printf "."
  sleep 5
done

info "Follow the log: tmux attach -t vllm   (Ctrl-b d to detach)"
info "Stop:          tmux kill-session -t vllm"
