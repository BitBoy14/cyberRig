#!/usr/bin/env bash
# smoke-test.sh — verifiserer at modellen svarer OG at tool-calling virker,
# før du kobler på harnesset. Sparer deg for mye feilsøking i agent-loopen.
set -euo pipefail
set -a; source "$HOME/.env"; set +a

BASE="http://localhost:${PORT:-8000}/v1"
AUTH="Authorization: Bearer ${OPENAI_API_KEY}"

echo "==> 1/3  Modell lastet?"
curl -s -H "$AUTH" "$BASE/models" | jq -r '.data[].id' || { echo "FEIL: ingen modell"; exit 1; }

echo "==> 2/3  Svarer på vanlig prompt?"
curl -s -H "$AUTH" -H "Content-Type: application/json" "$BASE/chat/completions" -d "{
  \"model\": \"${MODEL_ID}\",
  \"messages\": [{\"role\":\"user\",\"content\":\"Svar med ett ord: fungerer?\"}],
  \"max_tokens\": 10
}" | jq -r '.choices[0].message.content'

echo "==> 3/3  Tool-calling?  (ber modellen kalle en nmap-funksjon)"
curl -s -H "$AUTH" -H "Content-Type: application/json" "$BASE/chat/completions" -d "{
  \"model\": \"${MODEL_ID}\",
  \"messages\": [{\"role\":\"user\",\"content\":\"Scan host 10.0.0.5 for open ports.\"}],
  \"tools\": [{
    \"type\": \"function\",
    \"function\": {
      \"name\": \"run_nmap\",
      \"description\": \"Kjør en nmap-portskanning mot en host\",
      \"parameters\": {
        \"type\": \"object\",
        \"properties\": {\"target\": {\"type\": \"string\"}},
        \"required\": [\"target\"]
      }
    }
  }],
  \"tool_choice\": \"auto\"
}" | jq '.choices[0].message.tool_calls // "INGEN tool_call — sjekk --tool-call-parser"'

echo ""
echo "==> Hvis steg 3 viser et tool_call med target=10.0.0.5, er parseren riktig."
