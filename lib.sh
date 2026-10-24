#!/usr/bin/env bash
# lib.sh — shared colors, logging and helpers. Sourced by the other scripts.

# Colors (disabled automatically if not a terminal)
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
die()   { printf "\n${C_BOLD}${C_RED}✗ STOP: %s${C_RESET}\n" "$*" >&2; exit 1; }

# Run a command with a spinner and capture output to a file. Shows ✓/✗ at the end.
# usage: run_quiet "description" /path/to/log -- command args...
run_quiet() {
  local desc="$1"; shift
  local logf="$1"; shift
  [ "$1" = "--" ] && shift
  printf "    %s ... " "$desc"
  if "$@" >>"$logf" 2>&1; then
    printf "${C_GRN}✓${C_RESET}\n"; return 0
  else
    printf "${C_RED}✗${C_RESET}\n"
    printf "    ${C_DIM}(see %s)${C_RESET}\n" "$logf"
    return 1
  fi
}

# Read total/free VRAM in MiB (summed over cards). Sets VRAM_USED / VRAM_FREE / VRAM_TOTAL.
read_vram() {
  local q
  q=$(nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv,noheader,nounits 2>/dev/null) \
    || die "nvidia-smi failed — no GPU visible."
  VRAM_TOTAL=$(echo "$q" | awk -F',' '{s+=$1} END{print s}')
  VRAM_USED=$(echo "$q" | awk -F',' '{s+=$2} END{print s}')
  VRAM_FREE=$(echo "$q" | awk -F',' '{s+=$3} END{print s}')
}
