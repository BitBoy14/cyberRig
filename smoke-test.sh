#!/usr/bin/env bash
# smoke-test.sh — verifies model + tool-calling before you trust the harness.
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
[ -f "$HOME/.env" ] && { set -a; source "$HOME/.env"; set +a; }

BASE="http://localhost:${PORT:-8001}/v1"
AUTH="Authorization: Bearer ${OPENAI_API_KEY:-test123}"

printf "${C_BOLD}${C_CYA}=== SMOKE TEST ===${C_RESET}\n"

step "1/3  Model loaded?"
IDS=$(curl -s -H "$AUTH" "$BASE/models" | jq -r '.data[].id' 2>/dev/null) || true
if [ -n "$IDS" ]; then info "$IDS"; ok "Model responds"; else die "No model at $BASE — run ./serve.sh"; fi

step "2/3  Responds to a normal prompt?"
RESP=$(curl -s -H "$AUTH" -H "Content-Type: application/json" "$BASE/chat/completions" -d "{
  \"model\": \"${MODEL_ID}\",
  \"messages\": [{\"role\":\"user\",\"content\":\"Reply with one word: working?\"}],
  \"max_tokens\": 10
}" | jq -r '.choices[0].message.content' 2>/dev/null)
if [ -n "$RESP" ] && [ "$RESP" != "null" ]; then info "Reply: $RESP"; ok "Generation OK"; else warn "Empty reply — check ~/vllm.log"; fi

step "3/3  Tool-calling? (asks the model to call an nmap function)"
TC=$(curl -s -H "$AUTH" -H "Content-Type: application/json" "$BASE/chat/completions" -d "{
  \"model\": \"${MODEL_ID}\",
  \"messages\": [{\"role\":\"user\",\"content\":\"Scan host 10.0.0.5 for open ports.\"}],
  \"tools\": [{\"type\":\"function\",\"function\":{\"name\":\"run_nmap\",
    \"description\":\"Run an nmap port scan against a host\",
    \"parameters\":{\"type\":\"object\",\"properties\":{\"target\":{\"type\":\"string\"}},\"required\":[\"target\"]}}}],
  \"tool_choice\": \"auto\"
}" | jq '.choices[0].message.tool_calls' 2>/dev/null)
if [ -n "$TC" ] && [ "$TC" != "null" ]; then
  info "$TC"
  ok "Tool-calling works — the parser ($TOOL_PARSER) is correct"
else
  warn "No tool_call. Wrong --tool-call-parser? Qwen3-Coder=qwen3_coder, Qwen2.5/Hermes=hermes, Llama=llama3_json"
fi

echo ""
printf "${C_BOLD}${C_GRN}Smoke test done.${C_RESET}  Start harness: ./run-cai.sh\n"
