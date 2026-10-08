# cyberRig

Oppsett av en uncensored sikkerhetsmodell (`Qwen3.6-27B-Uncensored-Cyber`)
+ vLLM OpenAI-API + CAI-agent på en leid GPU (Vast.ai), via SSH.

Fra fersk instans til kjørende modell på fire kommandoer — og en
**preflight-sjekk som stopper deg før du kaster bort penger på feil instans**.

---

## Arbeidsflyt på en ny instans

Velg **vLLM-image** + **A100 80GB (dedikert!)** på Vast. SSH inn, så:

```bash
git clone https://github.com/BitBoy14/cyberRig rig && cd rig
chmod +x *.sh
./preflight.sh        # STOPP her hvis NO-GO — ikke installer på feil kort
./bootstrap.sh        # pakker, modell-nedlasting, CAI (mest nedlasting)
./serve.sh            # rydder VRAM, starter vLLM i tmux, venter til klar
./smoke-test.sh       # verifiserer modell + tool-calling
./run-cai.sh          # starter agenten
```

`config.env` er valgfri — `cp config.env.example config.env` og juster
hvis du vil endre modell, port eller GPU-antall. Uten den brukes fornuftige
standarder.

---

## Det viktigste: preflight

`./preflight.sh` sjekker at kortet faktisk er **ledig for deg**, ikke bare
stort. På delte Vast-verter kan en A100 80GB være opptatt av andre
leietakere — da får du aldri plass til modellen, uansett flagg.

**Regelen:** på en fersk instans skal `nvidia-smi` vise ~0 GB brukt VRAM.
Viser den 70+ GB brukt med "No running processes found", deler du kortet.
Da: **destroy instansen, velg en ny.** Ikke installer noe.

---

## Lærdommer innebygd i scriptene

Disse feilene er allerede håndtert — du skal slippe å treffe dem igjen:

| Problem | Håndtering |
|---------|-----------|
| `pip install -U vllm` brøt imaget (xformers-bygg feilet) | Scriptet rører ikke vLLM/torch hvis de finnes |
| `-U huggingface_hub` brøt transformers | Pinnet til `<2.0` |
| CAI rev ut vLLMs pakker | CAI i eget isolert venv + `mcp>=2.3` |
| Port 8000 opptatt av Vast caddy | Bruker port 8001 |
| Krasjet vLLM holdt VRAM som zombie | `serve.sh` rydder med `fuser -k /dev/nvidia*` |
| Delt/opptatt GPU | `preflight.sh` fanger det før install |

---

## Endre GPU-antall
`TP_SIZE=2` i `config.env` for 2× kort (tensor-parallellisme).

## Bytte modell
Sett `MODEL_ID` og riktig `TOOL_PARSER` i `config.env`. Feil parser →
tool-calls virker ikke; `smoke-test.sh` steg 3 fanger det.

## Ekstern tilgang til API-et
`bootstrap.sh` lager en API-nøkkel (vises til slutt + i `~/.env`).
OpenAI-kompatibelt endepunkt — pek Aider/OpenHands/egne skript på
`http://<ip>:8001/v1` med den nøkkelen.

## Filene
| Fil | Rolle |
|-----|-------|
| `preflight.sh` | Sjekker kort/VRAM/RAM/disk — kjør FØRST |
| `bootstrap.sh` | Installerer alt, laster ned modell, skriver `~/.env` |
| `serve.sh` | Rydder VRAM, starter vLLM i tmux |
| `smoke-test.sh` | Verifiserer modell + tool-calling |
| `run-cai.sh` | Starter CAI-agenten |
| `lib.sh` | Felles farger/logging (sources av de andre) |
| `config.env.example` | Mal for innstillinger |

---

## Viktig

**Autorisasjon:** Det som gjør arbeidet lovlig er skriftlig scope og samtykke
fra kunden — ikke at modellen nekter lite. Hold alt innenfor avtalt scope.

**Datakonfidensialitet:** Vast-verter er tredjepart og kan teknisk se trafikk
og disk. Bruk til lab/test — ikke ekte kundedata eller funn. For reelle
oppdrag: egen infrastruktur eller leverandør med databehandleravtale.

**Validering:** Abliterated community-modeller er ikke sikkerhetsrevidert.
Alt modellen genererer er forslag som må verifiseres manuelt — kjør aldri
generert kode blindt mot kundemiljø.
