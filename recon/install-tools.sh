#!/usr/bin/env bash
# install-tools.sh — robustly install pentest/recon tools on a Vast rig.
#
# Two callers:
#   1. bootstrap.sh, at setup — installs the default recon set so nmap and
#      searchsploit are ALWAYS present after ./bootstrap.sh.
#   2. the CAI agent, at runtime — when it finds a tool it needs is missing it
#      runs `$CYBERRIG_HOME/recon/install-tools.sh <tool> ...` to add it.
#
# Why this exists: the old bootstrap installed `exploitdb whatweb nmap` in ONE
# apt call. On a stock Ubuntu vLLM image `exploitdb` isn't in the repos, so the
# whole call failed and nmap/whatweb were skipped too ("not available on this
# rig"). Here every tool is installed INDEPENDENTLY — one failure never blocks
# the rest — and `searchsploit` has a git-clone fallback when apt has no
# `exploitdb` package.
#
# Usage:
#   ./install-tools.sh                      # default recon set (nmap searchsploit whatweb curl jq)
#   ./install-tools.sh nmap gobuster sqlmap # install specific tools (apt package == command, mostly)
#   ./install-tools.sh searchsploit         # apt exploitdb, else git-clone Exploit-DB
#
# Exit code: 0 if every requested tool ended up available, 1 otherwise. Printed
# summary lists what is / isn't present so the agent can read the result.
set -uo pipefail
cd "$(dirname "$0")"
source ../lib.sh 2>/dev/null || {
  # Minimal fallbacks when run outside the rig (keeps the agent path working).
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GRN=""; C_YEL=""; C_RED=""; C_BLU=""; C_CYA=""
  STEP_N=0
  step() { STEP_N=$((STEP_N+1)); printf "\n[%d] %s\n" "$STEP_N" "$*"; }
  info() { printf "    %s\n" "$*"; }
  ok()   { printf "    [ok] %s\n" "$*"; }
  warn() { printf "    [!] %s\n" "$*"; }
  die()  { printf "\n[STOP] %s\n" "$*" >&2; exit 1; }
}

# Root on Vast; use sudo only if present and needed.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 && SUDO="sudo" || warn "Not root and no sudo — installs may fail."
fi

export DEBIAN_FRONTEND=noninteractive
EXPLOITDB_DIR="${EXPLOITDB_DIR:-/opt/exploitdb}"
APT_UPDATED=0

apt_update_once() {
  [ "$APT_UPDATED" -eq 1 ] && return 0
  $SUDO apt-get update -qq >/dev/null 2>&1 || warn "apt-get update returned an error (often harmless)."
  APT_UPDATED=1
}

# Map a wanted command to the apt package that provides it, when they differ.
pkg_for() {
  case "$1" in
    searchsploit) echo "exploitdb" ;;
    nc)           echo "netcat-openbsd" ;;
    dig)          echo "dnsutils" ;;
    *)            echo "$1" ;;        # command name == package name (nmap, whatweb, gobuster, sqlmap, nikto, jq, curl, ...)
  esac
}

# searchsploit / Exploit-DB: apt first, then a git clone that works anywhere.
install_searchsploit() {
  command -v searchsploit >/dev/null 2>&1 && { ok "searchsploit already present"; return 0; }
  apt_update_once
  if $SUDO apt-get install -y -qq exploitdb >/dev/null 2>&1 && command -v searchsploit >/dev/null 2>&1; then
    searchsploit -u >/dev/null 2>&1 || true
    ok "searchsploit installed (apt exploitdb)"; return 0
  fi
  warn "apt has no 'exploitdb' on this image — falling back to git clone."
  command -v git >/dev/null 2>&1 || $SUDO apt-get install -y -qq git >/dev/null 2>&1
  if [ -x "$EXPLOITDB_DIR/searchsploit" ] || \
     $SUDO git clone --depth 1 https://gitlab.com/exploit-database/exploitdb.git "$EXPLOITDB_DIR" >/dev/null 2>&1; then
    $SUDO ln -sf "$EXPLOITDB_DIR/searchsploit" /usr/local/bin/searchsploit
    [ -f "$EXPLOITDB_DIR/.searchsploit_rc" ] && $SUDO ln -sf "$EXPLOITDB_DIR/.searchsploit_rc" "$HOME/.searchsploit_rc" 2>/dev/null || true
    if command -v searchsploit >/dev/null 2>&1; then
      ok "searchsploit installed (git clone -> $EXPLOITDB_DIR)"; return 0
    fi
  fi
  warn "Could not install searchsploit. vuln-recon.sh still works on CISA KEV + NVD (curl + jq)."
  return 1
}

# Generic apt tool: skip if already there, else install its package.
install_tool() {
  local cmd="$1" pkg; pkg="$(pkg_for "$1")"
  command -v "$cmd" >/dev/null 2>&1 && { ok "$cmd already present"; return 0; }
  apt_update_once
  if $SUDO apt-get install -y -qq "$pkg" >/dev/null 2>&1 && command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd installed (apt $pkg)"; return 0
  fi
  warn "Could not install '$cmd' (apt package '$pkg' not available here)."
  return 1
}

# Dispatch one requested tool to the right installer.
install_one() {
  case "$1" in
    searchsploit|exploitdb) install_searchsploit ;;
    *)                      install_tool "$1" ;;
  esac
}

# Default recon set when called with no args.
TOOLS=("$@")
[ "${#TOOLS[@]}" -eq 0 ] && TOOLS=(nmap searchsploit whatweb curl jq)

printf "${C_BOLD}${C_CYA}=== INSTALL TOOLS ===${C_RESET}\n"
info "Requested: ${TOOLS[*]}"

step "Installing"
RC=0
for t in "${TOOLS[@]}"; do
  install_one "$t" || RC=1
done

step "Result"
for t in "${TOOLS[@]}"; do
  c="$t"; [ "$t" = "exploitdb" ] && c="searchsploit"
  if command -v "$c" >/dev/null 2>&1; then ok "$c -> $(command -v "$c")"; else warn "$c -> MISSING"; fi
done

[ "$RC" -eq 0 ] && printf "\n${C_BOLD}${C_GRN}=== ALL REQUESTED TOOLS AVAILABLE ===${C_RESET}\n" \
                || printf "\n${C_BOLD}${C_YEL}=== SOME TOOLS COULD NOT BE INSTALLED (see above) ===${C_RESET}\n"
exit "$RC"
