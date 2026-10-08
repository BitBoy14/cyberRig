# vast-cyber-rig

Rask oppstart av en abliterated/uncensored sikkerhetsmodell + agent-harness
(CAI) på en leid GPU (Vast.ai). Fra tom instans til kjørende agent på
`git clone` + tre kommandoer — ingen manuell config hver gang.

**Standardmodell:** `philbert440/Qwen3.6-27B-Uncensored-Cyber` — 27B,
Qwen3.6-base, finjustert for offensiv/defensiv sikkerhet, tool-calling, 32k
kontekst. Kjører på **1× A100 80GB** (eller 2× for mer hoderom).

---

## Engangsoppsett (på egen maskin)
1. Push dette til et **privat** GitHub-repo.
2. Valgfritt: `cp config.env.example config.env` og juster (modell, TP_SIZE).

## Hver gang du leier en instans
Velg **vLLM-image** + **A100 80GB** på Vast, start, SSH inn:

```bash
git clone <ditt-private-repo> rig && cd rig
cp config.env.example config.env     # valgfritt — juster ved behov
chmod +x *.sh
./bootstrap.sh        # pakker, modell-nedlasting, CAI  (mest nedlasting)
./serve.sh            # starter vLLM i tmux, venter til klar
./smoke-test.sh       # verifiserer at modell + tool-calling virker
./run-cai.sh          # starter agent-harnesset
```

## To A100 i stedet for én
Sett `TP_SIZE=2` i `config.env` (eller `TP_SIZE=2 ./serve.sh`). Da deles
modellen over begge kort med tensor-parallellisme.

## Bytte modell
Rediger `config.env`:
```
MODEL_ID=<repo>
TOOL_PARSER=hermes        # Qwen-base ; llama3_json for Llama-base
```
Feil `TOOL_PARSER` → tool-calls virker ikke. `smoke-test.sh` steg 3 fanger det.

## Ekstern tilgang til API-et
`bootstrap.sh` lager en API-nøkkel (vises til slutt + i `~/.env`). Bruk den
som `Authorization: Bearer <nøkkel>` fra andre verktøy. Endepunktet er
OpenAI-kompatibelt (`/v1/chat/completions` m.m.), så Aider, OpenHands og
annet som snakker det formatet kan peke rett på det.

## Filene
| Fil | Hva den gjør |
|-----|--------------|
| `bootstrap.sh` | Installerer alt, laster ned modell, skriver `~/.env` |
| `serve.sh` | Starter vLLM i tmux med tool-calling |
| `smoke-test.sh` | Sjekker modell + at tool-calling faktisk virker |
| `run-cai.sh` | Starter CAI-agenten mot din vLLM |
| `config.env.example` | Mal for innstillinger |

## Nyttig
- Følg modell-loggen: `tmux attach -t vllm`  (Ctrl-b d for å koble fra)
- Stopp vLLM: `tmux kill-session -t vllm`
- GPU-status: `nvidia-smi`

---

## Viktig — les dette

**Autorisasjon:** Det som gjør arbeidet lovlig er skriftlig scope og
samtykke fra kunden — ikke at modellen nekter lite. Hold all aktivitet
innenfor avtalt scope.

**Datakonfidensialitet:** Vast.ai-verter er tredjepart og kan teknisk se
trafikk og disk. Bruk dette til **lab, trening og testing** — ikke ekte
kundedata, scope-detaljer eller funn fra engasjementer. For reelle oppdrag:
egen infrastruktur eller en leverandør med databehandleravtale.

**Validering:** Abliterated community-modeller er ikke sikkerhetsrevidert.
Behandl alt modellen genererer som forslag som må verifiseres manuelt — kjør
aldri generert kode blindt mot et kundemiljø.
