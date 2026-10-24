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

