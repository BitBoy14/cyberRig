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
