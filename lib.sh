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

