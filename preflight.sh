#!/usr/bin/env bash
# preflight.sh — RUN THIS FIRST, before anything else, on a fresh instance.
# Checks that GPU/VRAM/RAM/disk actually hold up AND that the card is free for YOU.
# The most important check is free VRAM: on shared Vast hosts the card can be
# busy with other tenants — then it's NO-GO no matter how large it is.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
[ -f ./config.env ] && { set -a; source ./config.env; set +a; }

# Requirements (overridable in config.env)
NEED_VRAM_FREE_GB="${NEED_VRAM_FREE_GB:-70}"   # model ~55GB + KV cache
NEED_RAM_GB="${NEED_RAM_GB:-32}"
NEED_DISK_GB="${NEED_DISK_GB:-120}"

printf "${C_BOLD}${C_CYA}=== PREFLIGHT ===${C_RESET}\n"

OK=1

step "GPU present?"
nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | while read -r n; do info "$n"; done \
  || die "No GPU. This is the wrong instance."
ok "GPU found"

step "VRAM — is the card FREE for you?"
read_vram
info "Total: $((VRAM_TOTAL/1024)) GB | Used: $((VRAM_USED/1024)) GB | Free: $((VRAM_FREE/1024)) GB"

# Is the used VRAM the image's OWN vLLM (reclaimable) or another tenant on a
# shared card (a real NO-GO)? Vast's vLLM images run their own vLLM under
# supervisor; serve.sh stops it and frees the memory before start. So if the
# supervisor service 'vllm' is running, the used VRAM is your own.
OWN_VLLM=0
if command -v supervisorctl >/dev/null 2>&1 \
   && supervisorctl status vllm 2>/dev/null | grep -q RUNNING; then
  OWN_VLLM=1
fi

if [ "$VRAM_USED" -gt 2048 ]; then
  if [ "$OWN_VLLM" -eq 1 ]; then
    warn "$((VRAM_USED/1024)) GB in use — but this is the image's OWN vLLM"
    warn "(the supervisor service 'vllm' is running). serve.sh stops it and"
    warn "frees the memory before start. This is NOT a shared card."
  else
    warn "The card already has $((VRAM_USED/1024)) GB in use."
    warn "On a fresh instance this should be ~0. If it isn't, you're SHARING"
    warn "the card with someone else — and you'll never fit the model."
    OK=0
  fi
else
  ok "The card is empty ($((VRAM_USED/1024)) GB used)"
fi

# Enough VRAM available? When the image's own vLLM is running, practically the
# whole card becomes free after serve.sh, so compute on total in that case.
if [ "$OWN_VLLM" -eq 1 ]; then
  AVAIL_GB=$((VRAM_TOTAL/1024))
  info "Available after serve.sh clears the image vLLM: ~${AVAIL_GB} GB"
else
  AVAIL_GB=$((VRAM_FREE/1024))
fi
if [ "$AVAIL_GB" -ge "$NEED_VRAM_FREE_GB" ]; then
  ok "Available VRAM is enough (>=${NEED_VRAM_FREE_GB} GB)"
else
  warn "Available VRAM ${AVAIL_GB} GB < requirement ${NEED_VRAM_FREE_GB} GB"
  OK=0
fi

step "RAM"
RAM=$(free -g | awk '/^Mem:/{print $2}')
info "${RAM} GB"
if [ "$RAM" -ge "$NEED_RAM_GB" ]; then ok "OK"; else warn "Too little (<${NEED_RAM_GB})"; OK=0; fi

step "Disk (home area)"
DISK=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
info "${DISK} GB free"
if [ "$DISK" -ge "$NEED_DISK_GB" ]; then ok "OK"; else warn "Too little (<${NEED_DISK_GB}) — turn up the disk slider on Vast"; OK=0; fi

echo ""
if [ "$OK" -eq 1 ]; then
  printf "${C_BOLD}${C_GRN}✅ GO — run ./bootstrap.sh${C_RESET}\n"
  if [ "$OWN_VLLM" -eq 1 ]; then
    printf "${C_DIM}   Note: the image's own vLLM holds VRAM now — serve.sh stops it automatically.${C_RESET}\n"
  fi
  exit 0
else
  printf "${C_BOLD}${C_RED}⛔ NO-GO — don't install anything on this instance.${C_RESET}\n"
  printf "${C_DIM}   Most common cause: shared/busy GPU or too little disk.${C_RESET}\n"
  printf "${C_DIM}   Destroy the instance and pick one with an empty, dedicated card.${C_RESET}\n"
  exit 1
fi
