#!/usr/bin/env bash
# install.sh — wires CyberRig's default pentest agent into CAI.
#
# Drops the custom agent + its prompt into CAI's `personal/` agents dir (the
# intended, reinstall-safe extension point CAI auto-discovers), then records
# CYBERRIG_HOME and CAI_AGENT_TYPE in ~/.env so ./run-cai.sh picks it up.
#
# Idempotent. Safe to re-run on a fresh instance. If CAI isn't installed, it
# explains what to do and exits without touching anything else.
set -uo pipefail
cd "$(dirname "$0")"
source ../lib.sh 2>/dev/null || { echo "cannot find ../lib.sh"; exit 1; }

RIG_HOME="$(cd .. && pwd)"
CAI_VENV="${CAI_VENV:-$HOME/cai-venv}"
AGENT_VAR="cyberrig_pentest_agent"   # module-level var name = CAI_AGENT_TYPE key

printf "${C_BOLD}${C_CYA}=== INSTALL CAI AGENT ===${C_RESET}\n"
info "Rig home:  $RIG_HOME"
info "CAI venv:  $CAI_VENV"

[ -x "$CAI_VENV/bin/python" ] || die "CAI venv not found at $CAI_VENV. Run ./bootstrap.sh (CAI step) first, or set CAI_VENV."

# --- 1. Locate CAI's agents dir ----------------------------------------
step "Locating CAI agents directory"
AGENTS_DIR="$("$CAI_VENV/bin/python" - <<'PY' 2>/dev/null
import os
try:
    import cai.agents as a
    print(os.path.dirname(a.__file__))
except Exception:
    pass
PY
)"
[ -n "$AGENTS_DIR" ] && [ -d "$AGENTS_DIR" ] || die "Could not import cai.agents from $CAI_VENV. Is CAI installed cleanly? (see bootstrap.log)"
PERSONAL="$AGENTS_DIR/personal"
ok "Found: $AGENTS_DIR"

# --- 2. Install the agent + prompt into personal/ ----------------------
step "Installing agent into personal/"
mkdir -p "$PERSONAL"
# personal/ must be an importable package for CAI's importlib to load it.
[ -f "$PERSONAL/__init__.py" ] || printf '# CyberRig personal agents\n' > "$PERSONAL/__init__.py"
cp -f ./cyberrig_pentest.py "$PERSONAL/cyberrig_pentest.py"
cp -f ./pentest-default.md  "$PERSONAL/pentest-default.md"
ok "Copied cyberrig_pentest.py + pentest-default.md -> $PERSONAL"

# --- 3. Verify CAI discovers it, learn the exact key -------------------
step "Verifying discovery"
KEY="$("$CAI_VENV/bin/python" - "$AGENT_VAR" <<'PY' 2>/dev/null
import sys
want = sys.argv[1]
try:
    from cai.agents import get_available_agents
    agents = get_available_agents()
    if want in agents:
        print(want)
    else:
        hits = [k for k in agents if "cyberrig" in k.lower()]
        print(hits[0] if hits else "")
except Exception as e:
    print("")
PY
)"
if [ -n "$KEY" ]; then
  ok "CAI discovered the agent as: $KEY"
else
  warn "Could not confirm discovery automatically. The files are in place;"
  warn "inside 'cai' you can run '/agent' and pick 'CyberRig Pentest' manually."
  KEY="$AGENT_VAR"
fi

# --- 4. Record CYBERRIG_HOME + CAI_AGENT_TYPE in ~/.env ----------------
step "Recording settings in ~/.env"
ENV="$HOME/.env"
touch "$ENV"
upsert() {  # upsert KEY VALUE into ~/.env (idempotent)
  local k="$1" v="$2"
  if grep -q "^${k}=" "$ENV" 2>/dev/null; then
    # portable in-place edit (GNU + BSD/macOS sed)
    sed -i.bak "s#^${k}=.*#${k}=${v}#" "$ENV" && rm -f "$ENV.bak"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV"
  fi
}
upsert CYBERRIG_HOME "$RIG_HOME"
upsert CAI_AGENT_TYPE "$KEY"
# Leave fetch_url in its safe default (blocks internal hosts). Only flip this
# for an authorized INTERNAL pentest, and prefer setting it per-run on the CLI.
grep -q '^CAI_FETCH_ALLOW_INTERNAL=' "$ENV" 2>/dev/null || \
  printf 'CAI_FETCH_ALLOW_INTERNAL=false\n' >> "$ENV"
ok "~/.env updated (CYBERRIG_HOME, CAI_AGENT_TYPE=$KEY)"

echo
printf "${C_BOLD}${C_GRN}=== DONE ===${C_RESET}\n"
info "Start the agent:   ./run-cai.sh   (uses CAI_AGENT_TYPE=$KEY)"
info "Or explicitly:     CAI_AGENT_TYPE=$KEY cai"
info "Pre-test recon:    ./recon/vuln-recon.sh --authorized <target>"
info "Re-run this after any CAI reinstall (personal/ lives inside the venv)."
