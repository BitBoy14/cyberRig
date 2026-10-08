#!/usr/bin/env bash
# install.sh — selvstendig oppsett av cyberRig-repoet.
# Kjør på en fersk Vast-instans (eller hvor som helst med git):
#   bash install.sh
# Skriver alle repo-filene til ./cyberRig og (valgfritt) pusher til GitHub.
set -euo pipefail

REPO_DIR="${REPO_DIR:-cyberRig}"
GITHUB_REMOTE="${GITHUB_REMOTE:-https://github.com/BitBoy14/cyberRig.git}"

mkdir -p "$REPO_DIR"
cd "$REPO_DIR"
echo "==> Skriver filer til $(pwd)"

echo '    - lib.sh'
cat > 'lib.sh' <<'EOF_LIB_SH'
#!/usr/bin/env bash
# lib.sh — felles farger, logging og hjelpere. Sources av de andre scriptene.

# Farger (deaktiveres automatisk hvis ikke terminal)
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_CYA=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYA=""
fi

STEP_N=0
step()  { STEP_N=$((STEP_N+1)); printf "\n${C_BOLD}${C_BLU}[%d] %s${C_RESET}\n" "$STEP_N" "$*"; }
info()  { printf "    ${C_DIM}%s${C_RESET}\n" "$*"; }
ok()    { printf "    ${C_GRN}✓ %s${C_RESET}\n" "$*"; }
warn()  { printf "    ${C_YEL}! %s${C_RESET}\n" "$*"; }
die()   { printf "\n${C_BOLD}${C_RED}✗ STOPP: %s${C_RESET}\n" "$*" >&2; exit 1; }

# Kjør en kommando med en spinner og fang output til fil. Viser ✓/✗ til slutt.
# bruk: run_quiet "beskrivelse" /sti/til/logg -- kommando args...
run_quiet() {
  local desc="$1"; shift
  local logf="$1"; shift
  [ "$1" = "--" ] && shift
  printf "    %s ... " "$desc"
  if "$@" >>"$logf" 2>&1; then
    printf "${C_GRN}✓${C_RESET}\n"; return 0
  else
    printf "${C_RED}✗${C_RESET}\n"
    printf "    ${C_DIM}(se %s)${C_RESET}\n" "$logf"
    return 1
  fi
}

# Les total/ledig VRAM i MiB (sum over kort). Setter VRAM_USED / VRAM_FREE / VRAM_TOTAL.
read_vram() {
  local q
  q=$(nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv,noheader,nounits 2>/dev/null) \
    || die "nvidia-smi feilet — ingen GPU synlig."
  VRAM_TOTAL=$(echo "$q" | awk -F',' '{s+=$1} END{print s}')
  VRAM_USED=$(echo "$q" | awk -F',' '{s+=$2} END{print s}')
  VRAM_FREE=$(echo "$q" | awk -F',' '{s+=$3} END{print s}')
}

EOF_LIB_SH

echo '    - preflight.sh'
cat > 'preflight.sh' <<'EOF_PREFLIGHT_SH'
#!/usr/bin/env bash
# preflight.sh — KJØR DETTE FØRST, før alt annet, på en fersk instans.
# Sjekker at GPU/VRAM/RAM/disk faktisk holder OG at kortet er ledig for DEG.
# Den viktigste sjekken er VRAM-ledig: på delte Vast-verter kan kortet være
# opptatt av andre leietakere — da er det NO-GO uansett hvor stort det er.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
[ -f ./config.env ] && { set -a; source ./config.env; set +a; }

# Krav (kan overstyres i config.env)
NEED_VRAM_FREE_GB="${NEED_VRAM_FREE_GB:-70}"   # modell ~55GB + KV-cache
NEED_RAM_GB="${NEED_RAM_GB:-32}"
NEED_DISK_GB="${NEED_DISK_GB:-120}"

printf "${C_BOLD}${C_CYA}=== PREFLIGHT ===${C_RESET}\n"

OK=1

step "GPU til stede?"
nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | while read -r n; do info "$n"; done \
  || die "Ingen GPU. Dette er feil instans."
ok "GPU funnet"

step "VRAM — er kortet LEDIG for deg?"
read_vram
info "Total: $((VRAM_TOTAL/1024)) GB | Brukt: $((VRAM_USED/1024)) GB | Ledig: $((VRAM_FREE/1024)) GB"
if [ "$VRAM_USED" -gt 2048 ]; then
  warn "Kortet har allerede $((VRAM_USED/1024)) GB i bruk."
  warn "På en fersk instans skal dette være ~0. Er det ikke det, DELER du"
  warn "kortet med noen andre — og da får du aldri plass til modellen."
  OK=0
else
  ok "Kortet er tomt ($((VRAM_USED/1024)) GB brukt)"
fi
if [ $((VRAM_FREE/1024)) -ge "$NEED_VRAM_FREE_GB" ]; then
  ok "Ledig VRAM holder (>=${NEED_VRAM_FREE_GB} GB)"
else
  warn "Ledig VRAM $((VRAM_FREE/1024)) GB < krav ${NEED_VRAM_FREE_GB} GB"
  OK=0
fi

step "RAM"
RAM=$(free -g | awk '/^Mem:/{print $2}')
info "${RAM} GB"
if [ "$RAM" -ge "$NEED_RAM_GB" ]; then ok "OK"; else warn "For lite (<${NEED_RAM_GB})"; OK=0; fi

step "Disk (hjemmeområde)"
DISK=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
info "${DISK} GB ledig"
if [ "$DISK" -ge "$NEED_DISK_GB" ]; then ok "OK"; else warn "For lite (<${NEED_DISK_GB}) — skru opp disk-slider på Vast"; OK=0; fi

echo ""
if [ "$OK" -eq 1 ]; then
  printf "${C_BOLD}${C_GRN}✅ GO — kjør ./bootstrap.sh${C_RESET}\n"
  exit 0
else
  printf "${C_BOLD}${C_RED}⛔ NO-GO — ikke installer noe på denne instansen.${C_RESET}\n"
  printf "${C_DIM}   Vanligste årsak: delt/opptatt GPU eller for lite disk.${C_RESET}\n"
  printf "${C_DIM}   Destroy instansen og velg en med tomt, dedikert kort.${C_RESET}\n"
  exit 1
fi

EOF_PREFLIGHT_SH

echo '    - bootstrap.sh'
cat > 'bootstrap.sh' <<'EOF_BOOTSTRAP_SH'
#!/usr/bin/env bash
# bootstrap.sh — installerer alt på en fersk Vast-instans (vLLM-image).
# KJØR ./preflight.sh FØRST. Hvert steg er isolert: feiler CAI, står
# vLLM-kjernen likevel. Idempotent — trygt å kjøre flere ganger.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
[ -f ./config.env ] && { set -a; source ./config.env; set +a; }

MODEL_ID="${MODEL_ID:-philbert440/Qwen3.6-27B-Uncensored-Cyber}"
TOOL_PARSER="${TOOL_PARSER:-hermes}"
MAX_LEN="${MAX_MODEL_LEN:-32768}"
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

EOF_BOOTSTRAP_SH

echo '    - serve.sh'
cat > 'serve.sh' <<'EOF_SERVE_SH'
#!/usr/bin/env bash
# serve.sh — rydder VRAM, starter vLLM i tmux, venter til API-et svarer.
# Lærdom: krasjede vLLM-starter etterlater zombie-prosesser som holder VRAM
# uten at nvidia-smi lister dem. Vi rydder med fuser før start.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
[ -f "$HOME/.env" ] && { set -a; source "$HOME/.env"; set +a; }

PORT="${PORT:-8001}"
TOOL_PARSER="${TOOL_PARSER:-hermes}"
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

# --- Rydd eventuelle zombie-prosesser ----------------------------------
step "Rydder gamle vLLM-prosesser og VRAM"
pkill -9 -f "vllm serve"  2>/dev/null || true
pkill -9 -f "EngineCore"  2>/dev/null || true
fuser -k /dev/nvidia* 2>/dev/null || true
sleep 3
read_vram
info "VRAM etter opprydding: $((VRAM_USED/1024)) GB brukt / $((VRAM_FREE/1024)) GB ledig"
if [ "$VRAM_USED" -gt 2048 ]; then
  warn "Fortsatt $((VRAM_USED/1024)) GB i bruk etter opprydding."
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

EOF_SERVE_SH

echo '    - smoke-test.sh'
cat > 'smoke-test.sh' <<'EOF_SMOKE_TEST_SH'
#!/usr/bin/env bash
# smoke-test.sh — verifiserer modell + tool-calling før du stoler på harnesset.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
[ -f "$HOME/.env" ] && { set -a; source "$HOME/.env"; set +a; }

BASE="http://localhost:${PORT:-8001}/v1"
AUTH="Authorization: Bearer ${OPENAI_API_KEY:-test123}"

printf "${C_BOLD}${C_CYA}=== SMOKE TEST ===${C_RESET}\n"

step "1/3  Modell lastet?"
IDS=$(curl -s -H "$AUTH" "$BASE/models" | jq -r '.data[].id' 2>/dev/null) || true
if [ -n "$IDS" ]; then info "$IDS"; ok "Modell svarer"; else die "Ingen modell på $BASE — kjør ./serve.sh"; fi

step "2/3  Svarer på vanlig prompt?"
RESP=$(curl -s -H "$AUTH" -H "Content-Type: application/json" "$BASE/chat/completions" -d "{
  \"model\": \"${MODEL_ID}\",
  \"messages\": [{\"role\":\"user\",\"content\":\"Svar med ett ord: fungerer?\"}],
  \"max_tokens\": 10
}" | jq -r '.choices[0].message.content' 2>/dev/null)
if [ -n "$RESP" ] && [ "$RESP" != "null" ]; then info "Svar: $RESP"; ok "Generering OK"; else warn "Tomt svar — sjekk ~/vllm.log"; fi

step "3/3  Tool-calling? (ber modellen kalle en nmap-funksjon)"
TC=$(curl -s -H "$AUTH" -H "Content-Type: application/json" "$BASE/chat/completions" -d "{
  \"model\": \"${MODEL_ID}\",
  \"messages\": [{\"role\":\"user\",\"content\":\"Scan host 10.0.0.5 for open ports.\"}],
  \"tools\": [{\"type\":\"function\",\"function\":{\"name\":\"run_nmap\",
    \"description\":\"Kjør en nmap-portskanning mot en host\",
    \"parameters\":{\"type\":\"object\",\"properties\":{\"target\":{\"type\":\"string\"}},\"required\":[\"target\"]}}}],
  \"tool_choice\": \"auto\"
}" | jq '.choices[0].message.tool_calls' 2>/dev/null)
if [ -n "$TC" ] && [ "$TC" != "null" ]; then
  info "$TC"
  ok "Tool-calling virker — parseren ($TOOL_PARSER) er riktig"
else
  warn "Ingen tool_call. Feil --tool-call-parser? Qwen-base=hermes, Llama-base=llama3_json"
fi

echo ""
printf "${C_BOLD}${C_GRN}Smoke test ferdig.${C_RESET}  Start harness: ./run-cai.sh\n"

EOF_SMOKE_TEST_SH

echo '    - run-cai.sh'
cat > 'run-cai.sh' <<'EOF_RUN_CAI_SH'
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

EOF_RUN_CAI_SH

echo '    - config.env.example'
cat > 'config.env.example' <<'EOF_CONFIG_ENV_EXAMPLE'
# Kopier til config.env og juster. config.env er i .gitignore.
# Alt her kan også settes som env-variabel på CLI (CLI vinner).

# --- Modell ---
MODEL_ID=philbert440/Qwen3.6-27B-Uncensored-Cyber
TOOL_PARSER=hermes          # Qwen-base -> hermes ; Llama-base -> llama3_json
MAX_MODEL_LEN=32768

# --- Maskinvare ---
TP_SIZE=1                   # antall GPU-er: 1x A100 80GB = 1, 2x = 2
GPU_UTIL=0.85               # andel VRAM vLLM får bruke (0.85 gir margin)

# --- Nettverk / auth ---
PORT=8001                  # 8000 er opptatt av Vast sin caddy — bruk 8001
# API_KEY=                 # tom = autogenereres ved bootstrap
# HF_TOKEN=                # valgfri Hugging Face-token for nedlasting

# --- Preflight-terskler (sjelden nødvendig å endre) ---
# NEED_VRAM_FREE_GB=70
# NEED_RAM_GB=32
# NEED_DISK_GB=120

EOF_CONFIG_ENV_EXAMPLE

echo '    - README.md'
cat > 'README.md' <<'EOF_README_MD'
# cyberRig

Oppsett av en uncensored sikkerhetsmodell (`Qwen3.6-27B-Uncensored-Cyber`)
+ vLLM OpenAI-API + CAI-agent på en leid GPU (Vast.ai), via SSH.

Fra fersk instans til kjørende modell på fire kommandoer — og en
**preflight-sjekk som stopper deg før du kaster bort penger på feil instans**.

---

## Arbeidsflyt på en ny instans

Velg **vLLM-image** + **A100 80GB (dedikert!)** på Vast. SSH inn, så:

```bash
git clone https://github.com/BitBoy14/cyberRig rig && cd rig
chmod +x *.sh
./preflight.sh        # STOPP her hvis NO-GO — ikke installer på feil kort
./bootstrap.sh        # pakker, modell-nedlasting, CAI (mest nedlasting)
./serve.sh            # rydder VRAM, starter vLLM i tmux, venter til klar
./smoke-test.sh       # verifiserer modell + tool-calling
./run-cai.sh          # starter agenten
```

`config.env` er valgfri — `cp config.env.example config.env` og juster
hvis du vil endre modell, port eller GPU-antall. Uten den brukes fornuftige
standarder.

---

## Det viktigste: preflight

`./preflight.sh` sjekker at kortet faktisk er **ledig for deg**, ikke bare
stort. På delte Vast-verter kan en A100 80GB være opptatt av andre
leietakere — da får du aldri plass til modellen, uansett flagg.

**Regelen:** på en fersk instans skal `nvidia-smi` vise ~0 GB brukt VRAM.
Viser den 70+ GB brukt med "No running processes found", deler du kortet.
Da: **destroy instansen, velg en ny.** Ikke installer noe.

---

## Lærdommer innebygd i scriptene

Disse feilene er allerede håndtert — du skal slippe å treffe dem igjen:

| Problem | Håndtering |
|---------|-----------|
| `pip install -U vllm` brøt imaget (xformers-bygg feilet) | Scriptet rører ikke vLLM/torch hvis de finnes |
| `-U huggingface_hub` brøt transformers | Pinnet til `<2.0` |
| CAI rev ut vLLMs pakker | CAI i eget isolert venv + `mcp>=2.3` |
| Port 8000 opptatt av Vast caddy | Bruker port 8001 |
| Krasjet vLLM holdt VRAM som zombie | `serve.sh` rydder med `fuser -k /dev/nvidia*` |
| Delt/opptatt GPU | `preflight.sh` fanger det før install |

---

## Endre GPU-antall
`TP_SIZE=2` i `config.env` for 2× kort (tensor-parallellisme).

## Bytte modell
Sett `MODEL_ID` og riktig `TOOL_PARSER` i `config.env`. Feil parser →
tool-calls virker ikke; `smoke-test.sh` steg 3 fanger det.

## Ekstern tilgang til API-et
`bootstrap.sh` lager en API-nøkkel (vises til slutt + i `~/.env`).
OpenAI-kompatibelt endepunkt — pek Aider/OpenHands/egne skript på
`http://<ip>:8001/v1` med den nøkkelen.

## Filene
| Fil | Rolle |
|-----|-------|
| `preflight.sh` | Sjekker kort/VRAM/RAM/disk — kjør FØRST |
| `bootstrap.sh` | Installerer alt, laster ned modell, skriver `~/.env` |
| `serve.sh` | Rydder VRAM, starter vLLM i tmux |
| `smoke-test.sh` | Verifiserer modell + tool-calling |
| `run-cai.sh` | Starter CAI-agenten |
| `lib.sh` | Felles farger/logging (sources av de andre) |
| `config.env.example` | Mal for innstillinger |

---

## Viktig

**Autorisasjon:** Det som gjør arbeidet lovlig er skriftlig scope og samtykke
fra kunden — ikke at modellen nekter lite. Hold alt innenfor avtalt scope.

**Datakonfidensialitet:** Vast-verter er tredjepart og kan teknisk se trafikk
og disk. Bruk til lab/test — ikke ekte kundedata eller funn. For reelle
oppdrag: egen infrastruktur eller leverandør med databehandleravtale.

**Validering:** Abliterated community-modeller er ikke sikkerhetsrevidert.
Alt modellen genererer er forslag som må verifiseres manuelt — kjør aldri
generert kode blindt mot kundemiljø.

EOF_README_MD

echo '    - .gitignore'
cat > '.gitignore' <<'EOF__GITIGNORE'
# Hemmeligheter og lokal tilstand — ALDRI sjekk inn
config.env
.env
*.log

# Modellvekter (store — lastes ned på instansen)
models/
*.safetensors
*.gguf
*.bin

EOF__GITIGNORE

chmod +x *.sh
echo "==> Alle filer skrevet."

# --- Valgfri GitHub-push -----------------------------------------------
read -r -p "Pushe til GitHub ($GITHUB_REMOTE)? [y/N] " ANS
if [[ "${ANS:-N}" =~ ^[Yy]$ ]]; then
  git init -q 2>/dev/null || true
  git add -A
  git -c user.email="mads@noracrm.no" -c user.name="BitBoy14" commit -q -m "cyberRig: robust Vast-oppsett med preflight og framdrift" || echo "   (ingenting å committe)"
  git branch -M main 2>/dev/null || true
  git remote remove origin 2>/dev/null || true
  git remote add origin "$GITHUB_REMOTE"
  echo "==> Pusher (overskriver repoet). Logg inn med brukernavn + personal access token når du blir bedt."
  git push -f -u origin main
  echo "==> Ferdig. Repoet er oppdatert."
else
  echo "==> Hoppet over push. Du kan pushe manuelt senere fra $(pwd):"
  echo "      git init && git add -A && git commit -m 'init'"
  echo "      git branch -M main && git remote add origin $GITHUB_REMOTE"
  echo "      git push -f -u origin main"
fi

echo ""
echo "Neste steg (på en instans med dedikert kort):"
echo "  cd $REPO_DIR && ./preflight.sh && ./bootstrap.sh && ./serve.sh && ./smoke-test.sh && ./run-cai.sh"
