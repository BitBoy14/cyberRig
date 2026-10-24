# cyberRig

Setup of an uncensored security model (`Qwen3.6-27B-Uncensored-Cyber`)
+ vLLM OpenAI API + a CAI agent on a rented GPU (Vast.ai), over SSH.

From a fresh instance to a running model in a few commands — plus a
**preflight check that stops you before you waste money on the wrong instance**,
and a **known-holes-first workflow** so the agent pulls every known CVE for a
target *before* it tests it.

---

## Workflow on a new instance

Pick a **vLLM image** + **A100 80GB (dedicated!)** on Vast. SSH in, then:

```bash
git clone https://github.com/BitBoy14/cyberRig rig && cd rig
chmod +x *.sh recon/*.sh cai-agent/*.sh
./preflight.sh        # STOP here if NO-GO — don't install on the wrong card
./bootstrap.sh        # packages, model download, CAI (mostly download)
./serve.sh            # clears VRAM, starts vLLM in tmux, waits until ready
./smoke-test.sh       # verifies model + tool-calling
./cai-agent/install.sh  # wires in the "known-holes-first" pentest agent
./run-cai.sh          # starts the agent
```

`config.env` is optional — `cp config.env.example config.env` and adjust if you
want to change model, port or GPU count. Without it, sensible defaults are used.

---

## The most important part: preflight

`./preflight.sh` checks that the card is actually **free for you**, not just
large. On shared Vast hosts an A100 80GB can be busy with other tenants — then
you'll never fit the model, no matter the flags.

**The rule:** on a fresh instance `nvidia-smi` should show ~0 GB used VRAM.
If it shows 70+ GB used with "No running processes found", you're sharing the
card. Then: **destroy the instance, pick a new one.** Don't install anything.

---

## Known-vulnerability intel & pre-test recon

The rig keeps a map of known holes and pulls the relevant ones **before** any
active testing — the same recon phase a real vulnerability scanner runs.

- **`recon/vuln-intel.md`** — the overview: the authoritative *living* sources
  (CISA KEV, NVD, Exploit-DB/searchsploit, OSV, PHP advisories, Patchstack) and a
  short **pinned** list of recent high-severity holes. On "is there a dedicated
  list?": there isn't one hand-maintained file — **CISA KEV and NVD are the
  source of truth**, and we query them live instead of letting a static list rot.
- **`recon/vuln-recon.sh <target>`** — fingerprints the target (product +
  version), then pulls the known holes for that exact version from CISA KEV + NVD
  (+ searchsploit) and writes a brief. Read-only: CVE lookups are public data; the
  only traffic to the target is one HEAD request, gated behind `--authorized`.

  ```bash
  ./recon/vuln-recon.sh --authorized https://target.example.com   # fingerprint + lookup
  ./recon/vuln-recon.sh --product php --version 8.2.10            # passive, lookup only
  ```

- **`cai-agent/`** — the default CAI agent (`cai-agent/install.sh` installs it).
  Its standing instruction is **fingerprint → run `vuln-recon.sh` and read
  `vuln-intel.md` → prioritize CISA KEV hits → only then test, within written
  scope**. It can read advisories online via CAI's `fetch_url` tool. So when you
  ask for a pentest of a PHP service, the known holes are downloaded first.

Pinned right now: **PHP "php2shell"** — CVE-2026-109618 / CVE-2026-109619,
unauthenticated RCE, CVSS 9.2, fixed in PHP 8.5.12 / 8.4.27 / 8.3.36 / 8.2.35
(emergency release 2026-10-21). A target below those is flagged critical.

Optional: set `NVD_API_KEY` to raise NVD's rate limit (5 → 50 calls / 30 s);
`apt-get install -y exploitdb` adds offline `searchsploit` results.

---

## Lessons baked into the scripts

These failures are already handled — you shouldn't hit them again:

| Problem | Handling |
|---------|----------|
| `pip install -U vllm` broke the image (xformers build failed) | The script doesn't touch vLLM/torch if they exist |
| `-U huggingface_hub` broke transformers | Pinned to `<2.0` |
| CAI tore out vLLM's packages | CAI in its own isolated venv + `mcp>=2.3` |
| Port 8000 taken by Vast's caddy | Uses port 8001 |
| A crashed vLLM held VRAM as a zombie | `serve.sh` clears it with `fuser -k /dev/nvidia*` |
| The Vast image's own vLLM (supervisor, autorestart) held ~21 GB VRAM | `serve.sh` runs `supervisorctl stop vllm model-ui ray` before cleanup; `preflight.sh` separates this from a genuinely shared card (GO, not NO-GO) |
| Shared/busy GPU | `preflight.sh` catches it before install |
| The `hermes` parser didn't match the Qwen3-Coder format the model sends (`<function=..><parameter=..>`) → tool-calls became plain text, never executed | Default parser is `qwen3_coder`; `smoke-test.sh` step 3 catches a mismatch |
| CAI filled the 32k context on long agent sessions → `ContextWindowExceededError`, crash | YaRN to 128k as default (`LONG_CONTEXT=1`) + `fp8` KV-cache to fit on one A100 80GB |
| The model is a Mamba hybrid: `max_num_seqs` (256) > available Mamba cache blocks at 128k → vLLM startup failed | Default `MAX_NUM_SEQS=16` (each sequence takes one Mamba block) |

---

## Change GPU count
`TP_SIZE=2` in `config.env` for 2× cards (tensor parallelism).

## Long context (YaRN)
The model is 32768 tokens native. By default we serve **128k via YaRN**
(`LONG_CONTEXT=1`, `MAX_MODEL_LEN=131072`) because CAI fills 32k quickly on long
agent sessions. `serve.sh` computes `factor = MAX_MODEL_LEN / 32768` itself and
writes the launch command to `~/.cyberrig_vllm_launch.sh` (cat it to inspect).
`KV_CACHE_DTYPE=fp8` halves the KV cache so 128k fits on one A100 80GB.

VRAM error at startup (`No available memory for the cache blocks`)? Lower
`MAX_MODEL_LEN` (e.g. 65536), lower `GPU_UTIL`, or use 2× cards. Don't need long
context: `LONG_CONTEXT=0` + `MAX_MODEL_LEN=32768`. If `--rope-scaling` fails on an
older vLLM, swap `rope_type` → `type` in `serve.sh`.

## Change model
Set `MODEL_ID` and the correct `TOOL_PARSER` in `config.env`. The parser must
match the tool-call format the model actually sends, otherwise the calls come out
as plain text and never run:
- Qwen3-Coder format (`<function=..><parameter=..>`) → `qwen3_coder` (default)
- Qwen2.5 / Hermes JSON (`<tool_call>{"name":..}</tool_call>`) → `hermes`
- Llama → `llama3_json`

`smoke-test.sh` step 3 catches the wrong parser before you trust the harness.

## External access to the API
`bootstrap.sh` creates an API key (shown at the end + in `~/.env`).
OpenAI-compatible endpoint — point Aider/OpenHands/your own scripts at
`http://<ip>:8001/v1` with that key.

## The files
| File | Role |
|------|------|
| `preflight.sh` | Checks card/VRAM/RAM/disk — run FIRST |
| `bootstrap.sh` | Installs everything, downloads the model, writes `~/.env` |
| `serve.sh` | Clears VRAM, starts vLLM in tmux |
| `smoke-test.sh` | Verifies model + tool-calling |
| `cai-agent/install.sh` | Wires the known-holes-first agent into CAI |
| `cai-agent/cyberrig_pentest.py` | The default CAI agent (instructions + tools) |
| `cai-agent/pentest-default.md` | The agent's standing instruction |
| `recon/vuln-recon.sh` | Pulls known CVEs for a target before testing |
| `recon/vuln-intel.md` | Overview of sources + pinned recent holes |
| `run-cai.sh` | Starts the CAI agent |
| `lib.sh` | Shared colors/logging (sourced by the others) |
| `config.env.example` | Settings template |

---

## Important

**Authorization:** what makes the work legal is written scope and consent from
the customer — not that the model refuses little. Keep everything within the
agreed scope.

**Data confidentiality:** Vast hosts are third parties and can technically see
traffic and disk. Use for lab/test — not real customer data or findings. For real
engagements: your own infrastructure or a provider with a data-processing
agreement.

**Validation:** Abliterated community models are not security-audited. Everything
the model generates is a suggestion that must be verified manually — never run
generated code blindly against a customer environment.
