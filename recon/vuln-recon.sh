#!/usr/bin/env bash
# vuln-recon.sh — pull KNOWN holes for a target BEFORE an authorized test.
#
# What it does:
#   1. (optional, requires authorization) fingerprints the target: Server/X-Powered-By
#      -> product + version.
#   2. looks up known holes in the authoritative, living sources for that version:
#        - CISA KEV   (holes actually exploited in the wild — source of truth)
#        - NVD API    (all CVEs with CVSS for the exact product+version)
#        - searchsploit (public PoC/exploit, if installed)
#   3. writes a markdown brief the agent reads before the test starts.
#
# It is READ-ONLY: CVE lookups are public data; the only traffic sent to the
# TARGET is one HEAD request for fingerprinting, and that requires --authorized.
# No exploitation, no payloads.
#
# Usage:
#   ./vuln-recon.sh --authorized https://target.example.com       # fingerprint + lookup
#   ./vuln-recon.sh --product php --version 8.2.10                 # passive, lookup only
#   ./vuln-recon.sh --no-fingerprint https://target --product php  # never touch target
#
# Options:
#   --authorized          confirm written scope -> allow ONE HEAD against the target
#   --no-fingerprint      send nothing to the target (pure passive DB lookup)
#   --product <name>      product to look up (default: inferred, else 'php')
#   --version <x.y.z>     version to match in NVD (else: criticals for the product)
#   --out <dir>           where the brief is written (default: ./recon/out)
#   NVD_API_KEY=...       (env) raises NVD's rate limit 5 -> 50 calls / 30 s
set -uo pipefail
cd "$(dirname "$0")"
source ../lib.sh 2>/dev/null || { echo "cannot find ../lib.sh"; exit 1; }

AUTHORIZED=0; NO_FP=0; PRODUCT=""; VERSION=""; TARGET=""
OUT="${CYBERRIG_OUT:-./out}"
[ "${CYBERRIG_AUTHORIZED:-0}" = "1" ] && AUTHORIZED=1

while [ $# -gt 0 ]; do
  case "$1" in
    --authorized)     AUTHORIZED=1 ;;
    --no-fingerprint) NO_FP=1 ;;
    --product)        PRODUCT="${2:-}"; shift ;;
    --version)        VERSION="${2:-}"; shift ;;
    --out)            OUT="${2:-}"; shift ;;
    -h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)               die "unknown option: $1" ;;
    *)                TARGET="$1" ;;
  esac
  shift
done

command -v curl >/dev/null || die "curl missing."
command -v jq   >/dev/null || die "jq missing (apt-get install -y jq)."

printf "${C_BOLD}${C_CYA}=== VULN-RECON ===${C_RESET}\n"
[ -n "$TARGET" ] && info "Target:   $TARGET"
mkdir -p "$OUT"

# --- 1. Fingerprint (touches the target -> requires authorization) -----
SERVER=""; XPOWERED=""
if [ -n "$TARGET" ] && [ "$NO_FP" -eq 0 ]; then
  if [ "$AUTHORIZED" -ne 1 ]; then
    warn "No --authorized: skipping fingerprint (no traffic to the target)."
    warn "CVE lookups still run. Pass --authorized once you have written scope,"
    warn "or give --product/--version manually for version-precise matches."
  else
    step "Fingerprint (one HEAD request to the target)"
    HDRS="$(curl -sS -I -L --max-time 12 "$TARGET" 2>/dev/null)" \
      || warn "HEAD to the target failed (continuing with manual values if given)."
    SERVER="$(printf '%s' "$HDRS"   | awk -F': ' 'tolower($1)=="server"{print $2}'       | tr -d '\r' | head -1)"
    XPOWERED="$(printf '%s' "$HDRS" | awk -F': ' 'tolower($1)=="x-powered-by"{print $2}' | tr -d '\r' | head -1)"
    [ -n "$SERVER" ]   && ok "Server:       $SERVER"
    [ -n "$XPOWERED" ] && ok "X-Powered-By: $XPOWERED"
    [ -z "$SERVER$XPOWERED" ] && warn "No revealing headers (good for the target; don't guess the version)."
    # Infer product/version from headers unless set explicitly
    if [ -z "$VERSION" ]; then
      VERSION="$(printf '%s %s' "$XPOWERED" "$SERVER" | grep -oiE 'php/[0-9]+(\.[0-9]+){1,2}' | head -1 | cut -d/ -f2)"
    fi
    if [ -z "$PRODUCT" ]; then
      printf '%s %s' "$XPOWERED" "$SERVER" | grep -qi php && PRODUCT="php"
    fi
  fi
fi
[ -z "$PRODUCT" ] && PRODUCT="php"   # default focus for this rig
[ -n "$VERSION" ] && info "Looking up: $PRODUCT $VERSION" || info "Looking up: $PRODUCT (no version -> criticals)"

SAFE="$(printf '%s' "${TARGET:-$PRODUCT}" | sed 's#https\{0,1\}://##; s#[^A-Za-z0-9._-]#_#g')"
REPORT="$OUT/known-vulns-${SAFE}-$(date +%Y%m%d).md"
: > "$REPORT"
{
  echo "# Known holes — $PRODUCT ${VERSION:-(unspecified version)}"
  echo
  echo "> Generated $(date '+%Y-%m-%d %H:%M') by \`vuln-recon.sh\`. Target: \`${TARGET:-–}\`."
  echo "> Sources: CISA KEV, NVD, searchsploit. Prioritize KEV hits (proven exploited) first."
  echo "> Always match against the ACTUAL version before concluding. No payloads here."
  echo
  [ -n "$SERVER" ]   && echo "- Server: \`$SERVER\`"
  [ -n "$XPOWERED" ] && echo "- X-Powered-By: \`$XPOWERED\`"
  echo
} >> "$REPORT"

# --- 2. CISA KEV — actively exploited holes (source of truth) ----------
step "CISA KEV (actively exploited holes)"
KEV="$OUT/cisa-kev.json"
KEV_URL="https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
if curl -sS --max-time 30 "$KEV_URL" -o "$KEV" 2>/dev/null && jq empty "$KEV" 2>/dev/null; then
  COUNT="$(jq --arg p "$PRODUCT" '[.vulnerabilities[]
            | select((.vendorProject+" "+.product+" "+.vulnerabilityName+" "+.shortDescription)
            | ascii_downcase | contains($p|ascii_downcase))] | length' "$KEV")"
  ok "KEV feed loaded — $COUNT hits for '$PRODUCT'"
  {
    echo "## CISA KEV — proven exploited (check FIRST)"
    echo
    if [ "${COUNT:-0}" -gt 0 ]; then
      echo "| CVE | Name | Added | Required action |"
      echo "|-----|------|-------|-----------------|"
      jq -r --arg p "$PRODUCT" '.vulnerabilities[]
        | select((.vendorProject+" "+.product+" "+.vulnerabilityName+" "+.shortDescription)
          | ascii_downcase | contains($p|ascii_downcase))
        | "| \(.cveID) | \(.vulnerabilityName) | \(.dateAdded) | \(.requiredAction|gsub("\n";" ")) |"' "$KEV"
    else
      echo "_No KEV hits for '$PRODUCT'._"
    fi
    echo
  } >> "$REPORT"
else
  warn "Could not fetch/parse the KEV feed (continuing)."
  echo -e "## CISA KEV\n\n_Feed unavailable at run time._\n" >> "$REPORT"
fi

# --- 3. NVD — all CVEs for product+version -----------------------------
step "NVD API (CVEs + CVSS)"
NVD_BASE="https://services.nvd.nist.gov/rest/json/cves/2.0"
if [ -n "$VERSION" ]; then
  NVD_URL="$NVD_BASE?virtualMatchString=cpe:2.3:a:${PRODUCT}:${PRODUCT}:${VERSION}&resultsPerPage=50"
  NVD_DESC="CVEs covering $PRODUCT $VERSION"
else
  NVD_URL="$NVD_BASE?keywordSearch=${PRODUCT}&cvssV3Severity=CRITICAL&resultsPerPage=30"
  NVD_DESC="critical CVEs with keyword '$PRODUCT' (no version given)"
fi
NVD_HDR=(); [ -n "${NVD_API_KEY:-}" ] && NVD_HDR=(-H "apiKey: $NVD_API_KEY")
NVD="$OUT/nvd.json"
if curl -sS --max-time 40 ${NVD_HDR[@]+"${NVD_HDR[@]}"} "$NVD_URL" -o "$NVD" 2>/dev/null && jq -e '.vulnerabilities' "$NVD" >/dev/null 2>&1; then
  NC="$(jq '.vulnerabilities | length' "$NVD")"
  ok "NVD responded — $NC CVEs ($NVD_DESC)"
  {
    echo "## NVD — $NVD_DESC"
    echo
    if [ "${NC:-0}" -gt 0 ]; then
      echo "| CVE | CVSS | Published | Summary |"
      echo "|-----|------|-----------|---------|"
      jq -r '.vulnerabilities[] | .cve
        | (.metrics.cvssMetricV40[0].cvssData.baseScore
           // .metrics.cvssMetricV31[0].cvssData.baseScore
           // .metrics.cvssMetricV30[0].cvssData.baseScore
           // .metrics.cvssMetricV2[0].cvssData.baseScore // "–") as $s
        | (.descriptions[]? | select(.lang=="en") | .value) as $d
        | "| \(.id) | \($s) | \(.published|split("T")[0]) | \(($d|gsub("\n";" "))[0:160]) |"' "$NVD" \
        | sort -t'|' -k3 -rn | head -40
    else
      echo "_No NVD hits. Try a more precise --version, or check the product name._"
    fi
    echo
  } >> "$REPORT"
else
  warn "NVD did not respond as expected (rate limit? set NVD_API_KEY). Continuing."
  echo -e "## NVD\n\n_API unavailable/rate-limited at run time. Look up manually: $NVD_URL_\n" >> "$REPORT"
fi

# --- 4. searchsploit — public PoC/exploit (if installed) ---------------
step "searchsploit (Exploit-DB offline)"
if command -v searchsploit >/dev/null 2>&1; then
  SS="$(searchsploit --disable-colour "$PRODUCT" ${VERSION:+$VERSION} 2>/dev/null | sed -n '1,40p')"
  if [ -n "$SS" ]; then
    ok "searchsploit returned hits"
    { echo "## searchsploit — public PoC/exploit"; echo; echo '```'; echo "$SS"; echo '```'; echo; } >> "$REPORT"
  else
    info "No searchsploit hits."
  fi
else
  info "searchsploit not installed — skipping (apt-get install -y exploitdb)."
  echo -e "## searchsploit\n\n_Not installed on this host._\n" >> "$REPORT"
fi

# --- 5. Pinned from vuln-intel (PHP php2shell) -------------------------
if printf '%s' "$PRODUCT" | grep -qi php; then
  {
    echo "## Pinned: PHP php2shell (CVE-2026-109618 / CVE-2026-109619)"
    echo
    echo "Unauthenticated RCE, CVSS 9.2, fixed in PHP **8.5.12 / 8.4.27 / 8.3.36 / 8.2.35** (2026-10-21)."
    if [ -n "$VERSION" ]; then
      echo
      echo "> Fingerprinted version: **$VERSION**. If it is older than the fixed ones above"
      echo "> (or on a branch < 8.2), the target is likely exposed → **critical**."
    fi
    echo
    echo "Details and mitigation: see \`recon/vuln-intel.md\` → \"Pinned\"."
    echo
  } >> "$REPORT"
fi

echo
ok "Brief written: $REPORT"
info "Read it BEFORE active testing. Prioritize KEV hits, then criticals with a known PoC."
printf "%s\n" "$REPORT"
