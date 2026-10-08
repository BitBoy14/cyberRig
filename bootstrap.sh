#!/usr/bin/env bash
# bootstrap.sh — fra tom Vast.ai-instans (vLLM/PyTorch-image) til kjørende
# modell + CAI-harness. Idempotent: trygt å kjøre flere ganger.
set -euo pipefail

# ----------------------------------------------------------------------
# Konfig — overstyr med env-variabler, eller legg dem i config.env
# (kopier config.env.example -> config.env). CLI-env vinner over fil.
# ----------------------------------------------------------------------
[ -f "$(dirname "$0")/config.env" ] && { set -a; source "$(dirname "$0")/config.env"; set +a; }

MODEL_ID="${MODEL_ID:-philbert440/Qwen3.6-27B-Uncensored-Cyber}"
TOOL_PARSER="${TOOL_PARSER:-hermes}"            # Qwen-base -> hermes
MAX_LEN="${MAX_MODEL_LEN:-32768}"               # modellen støtter 32k
PORT="${PORT:-8000}"
TP_SIZE="${TP_SIZE:-1}"                          # 1 kort = 1, 2x A100 = 2
GPU_UTIL="${GPU_UTIL:-0.90}"
API_KEY="${API_KEY:-$(openssl rand -hex 16)}"
MODEL_DIR="${MODEL_DIR:-$HOME/models}"

echo "==> Modell:       $MODEL_ID"
echo "==> Tool-parser:  $TOOL_PARSER"
echo "==> Tensor-par.:  $TP_SIZE kort"
echo "==> API-nøkkel:   $API_KEY   (lagres i ./.env)"

# ----------------------------------------------------------------------
# 1. Systempakker
# ----------------------------------------------------------------------
echo "==> Installerer systempakker..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git git-lfs tmux curl jq openssl >/dev/null
git lfs install --skip-repo

# ----------------------------------------------------------------------
# 2. Python-avhengigheter (vLLM finnes i vllm-imaget; no-op der,
#    men sikrer det på PyTorch-imaget)
# ----------------------------------------------------------------------
echo "==> Sikrer vLLM + HF CLI..."
pip install -q -U "huggingface_hub[cli]" vllm

# Valgfri HF-token for raskere/garantert nedlasting (sett HF_TOKEN i config.env)
if [ -n "${HF_TOKEN:-}" ]; then
  echo "==> Logger inn på Hugging Face..."
  hf auth login --token "$HF_TOKEN" >/dev/null 2>&1 || true
fi

# ----------------------------------------------------------------------
# 3. Last ned modellen eksplisitt (ser fremdrift / feiler tidlig)
# ----------------------------------------------------------------------
echo "==> Laster ned modell til $MODEL_DIR ..."
mkdir -p "$MODEL_DIR"
hf download "$MODEL_ID" --local-dir "$MODEL_DIR/$(basename "$MODEL_ID")"

# ----------------------------------------------------------------------
# 4. Installer CAI-harness
# ----------------------------------------------------------------------
echo "==> Installerer CAI (Cybersecurity AI)..."
pip install -q cai-framework || {
  echo "   pip-pakke feilet, cloner fra git i stedet..."
  git clone https://github.com/aliasrobotics/cai.git "$HOME/cai" || true
  [ -d "$HOME/cai" ] && pip install -q -e "$HOME/cai"
}

# ----------------------------------------------------------------------
# 5. Skriv .env for harness + senere bruk
# ----------------------------------------------------------------------
cat > "$HOME/.env" <<EOF
OPENAI_API_BASE=http://localhost:${PORT}/v1
OPENAI_BASE_URL=http://localhost:${PORT}/v1
OPENAI_API_KEY=${API_KEY}
CAI_MODEL=openai/${MODEL_ID}
MODEL_ID=${MODEL_ID}
TOOL_PARSER=${TOOL_PARSER}
MAX_MODEL_LEN=${MAX_LEN}
PORT=${PORT}
TP_SIZE=${TP_SIZE}
GPU_UTIL=${GPU_UTIL}
EOF
echo "==> Skrev $HOME/.env"

echo ""
echo "============================================================"
echo " Oppsett ferdig."
echo "   Start modell:   ./serve.sh"
echo "   Start harness:  ./run-cai.sh"
echo "   API-nøkkel:     ${API_KEY}"
echo "============================================================"
