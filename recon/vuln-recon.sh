#!/usr/bin/env bash
# vuln-recon.sh — pull KNOWN holes for a target BEFORE an authorized test.
#
# What it does:
#   1. (optional, requires authorization) fingerprints the target: HTTP
#      headers + body (Server/X-Powered-By/generator/title/cookies), plus
#      whatweb and a container-safe nmap -sV when installed, and flags any
#      WAF/CDN (Cloudflare etc.) -> product + version.
#   2. looks up known holes in the authoritative, living sources for that version:
#        - CISA KEV   (holes actually exploited in the wild — source of truth)
#        - NVD API    (all CVEs with CVSS for the exact product+version)
#        - searchsploit (public PoC/exploit, if installed)
#   3. writes a markdown brief the agent reads before the test starts.
#
# It is READ-ONLY: CVE lookups are public data; the traffic sent to the TARGET is
# ordinary read-only requests (a GET, optional whatweb, and a light nmap service
# scan), and that requires --authorized. No exploitation, no payloads.
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

# --- 1. Fingerprint (read-only, but touches the target -> needs authorization) -
# Richer than a single HEAD: a GET for headers+body (meta generator, title,
# cookies), plus whatweb and a container-safe nmap -sV when available. All
# read-only — no payloads, no exploitation. A weak fingerprint is what makes the
# whole brief useless, so we gather what we can and, when we find nothing, we say
# so honestly instead of guessing "php".
SERVER=""; XPOWERED=""; GENERATOR=""; TITLE=""; COOKIES=""; WAF=""
NMAP_OUT=""; WHATWEB_OUT=""; FP_SRC=""
UA="Mozilla/5.0 (X11; Linux x86_64) CyberRig-Recon"
if [ -n "$TARGET" ] && [ "$NO_FP" -eq 0 ]; then
  if [ "$AUTHORIZED" -ne 1 ]; then
    warn "No --authorized: skipping fingerprint (no traffic to the target)."
    warn "CVE lookups still run. Pass --authorized once you have written scope,"
    warn "or give --product/--version manually for version-precise matches."
  else
    HOST="$(printf '%s' "$TARGET" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#:[0-9]+$##')"

    step "Fingerprint — HTTP headers + body (GET)"
    BODY="$OUT/.fp-body.$$"; HDRS=""
    HDRS="$(curl -sS -D - -o "$BODY" -L --max-time 15 -A "$UA" "$TARGET" 2>/dev/null)" \
      || warn "GET to the target failed (continuing with manual values if given)."
    _hdr() { printf '%s' "$HDRS" | awk -F': ' -v k="$1" 'tolower($1)==k{sub($1": ","");print;exit}' | tr -d '\r'; }
    SERVER="$(_hdr server)"; XPOWERED="$(_hdr x-powered-by)"
    COOKIES="$(printf '%s' "$HDRS" | awk -F'[:=]' 'tolower($1)=="set-cookie"{print $2}' | tr -d '\r ' | paste -sd, - 2>/dev/null)"
    # WAF / CDN markers — vital: hammering one of these gets your source IP blocked.
    printf '%s' "$HDRS" | grep -qiE 'cf-ray|server:\s*cloudflare' && WAF="Cloudflare"
    [ -z "$WAF" ] && printf '%s' "$HDRS" | grep -qiE 'x-sucuri|incap_ses|akamai|x-akamai|aws.?waf|x-amz-cf' && WAF="CDN/WAF"
    if [ -s "$BODY" ]; then
      GENERATOR="$(grep -ioE '<meta[^>]+name=["'\'']generator["'\''][^>]*>' "$BODY" | grep -ioE 'content=["'\''][^"'\'']*' | sed -E 's/content=["'\'']//' | head -1)"
      TITLE="$(grep -ioE '<title>[^<]*' "$BODY" | sed -E 's/<title>//I' | head -1 | cut -c1-120)"
    fi
    rm -f "$BODY" 2>/dev/null
    [ -n "$SERVER" ]    && ok "Server:        $SERVER"
    [ -n "$XPOWERED" ]  && ok "X-Powered-By:  $XPOWERED"
    [ -n "$GENERATOR" ] && ok "Generator:     $GENERATOR"
    [ -n "$WAF" ]       && warn "WAF/CDN detected: $WAF — pace requests; aggressive scanning WILL get this rig's IP blocked."
    [ -z "$SERVER$XPOWERED$GENERATOR" ] && warn "No revealing HTTP markers (don't guess — try nmap/whatweb below)."

    # whatweb — richer app/framework fingerprint (if installed)
    if command -v whatweb >/dev/null 2>&1; then
      step "Fingerprint — whatweb"
      WHATWEB_OUT="$(whatweb --color=never --no-errors -a 1 "$TARGET" 2>/dev/null | sed -n '1,8p')"
      [ -n "$WHATWEB_OUT" ] && ok "whatweb returned data" || info "whatweb returned nothing."
    fi

    # nmap -sV — service/version. Container-safe: -sT (TCP connect, no raw
    # sockets), -Pn (skip ping/ICMP, also raw-socket), --unprivileged. Vast
    # containers can't open raw sockets, so the default SYN scan (-sS) fails.
    if command -v nmap >/dev/null 2>&1 && [ -n "$HOST" ]; then
      step "Fingerprint — nmap -sV (TCP connect, container-safe)"
      NMAP_OUT="$(nmap -Pn -sT --unprivileged -sV --version-light --open \
                   -p 80,443,8080,8443 -T4 --host-timeout 90s "$HOST" 2>/dev/null \
                   | grep -E '^[0-9]+/tcp|Service Info|OS details' | sed -n '1,12p')"
      [ -n "$NMAP_OUT" ] && ok "nmap returned open ports/services" || info "nmap found nothing (filtered/blocked?)."
    fi

    # --- Infer product + version from everything we gathered ---------------
    ALL="$XPOWERED | $SERVER | $GENERATOR | $WHATWEB_OUT | $NMAP_OUT"
    if [ -z "$VERSION" ]; then
      # PHP first (the rig's focus), then common web servers.
      VERSION="$(printf '%s' "$ALL" | grep -oiE 'php/[0-9]+(\.[0-9]+){1,2}'     | head -1 | cut -d/ -f2)"
      [ -z "$VERSION" ] && VERSION="$(printf '%s' "$ALL" | grep -oiE '(nginx|apache|openresty|litespeed)/[0-9]+(\.[0-9]+){1,2}' | head -1 | cut -d/ -f2)"
    fi
    if [ -z "$PRODUCT" ]; then
      if printf '%s' "$ALL" | grep -qi php; then PRODUCT="php"
      else PRODUCT="$(printf '%s' "$ALL" | grep -oiE 'nginx|apache|openresty|litespeed|iis|tomcat|wordpress|drupal|joomla' | head -1 | tr 'A-Z' 'a-z')"
      fi
    fi
    [ -n "$PRODUCT" ] && FP_SRC="fingerprinted"
  fi
fi
# Last-resort fallback so the DB lookups still have a keyword — but flag it clearly
# as an ASSUMPTION, not a fingerprint, so the agent knows to prove the stack itself.
if [ -z "$PRODUCT" ]; then PRODUCT="php"; FP_SRC="ASSUMED (not fingerprinted — prove the real stack before trusting this brief)"; fi
[ -n "$VERSION" ] && info "Looking up: $PRODUCT $VERSION" || info "Looking up: $PRODUCT (no version -> criticals) [$FP_SRC]"

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
  echo "## Fingerprint"
  echo
  echo "- Product looked up: **$PRODUCT** ${VERSION:+(version **$VERSION**)} — _${FP_SRC}_"
  [ -n "$SERVER" ]    && echo "- Server: \`$SERVER\`"
  [ -n "$XPOWERED" ]  && echo "- X-Powered-By: \`$XPOWERED\`"
  [ -n "$GENERATOR" ] && echo "- Generator: \`$GENERATOR\`"
  [ -n "$TITLE" ]     && echo "- Title: \`$TITLE\`"
  [ -n "$COOKIES" ]   && echo "- Cookies: \`$COOKIES\`"
  if [ -n "$WAF" ]; then
    echo
    echo "> ⚠️ **WAF/CDN detected: $WAF.** Requests are proxied and rate-limited."
    echo "> Pace your testing — bursts of requests will get this rig's source IP"
    echo "> blocked (you'll see connection refused / HTTP 000). Fingerprint the"
    echo "> ORIGIN where possible; results below describe the edge otherwise."
  fi
  if [ -n "$WHATWEB_OUT" ]; then echo; echo "**whatweb:**"; echo '```'; printf '%s\n' "$WHATWEB_OUT"; echo '```'; fi
  if [ -n "$NMAP_OUT" ];   then echo; echo "**nmap -sV:**"; echo '```'; printf '%s\n' "$NMAP_OUT"; echo '```'; fi
  if [ "${FP_SRC%% *}" = "ASSUMED" ]; then
    echo
    echo "> ⚠️ **Stack not confirmed.** No product/version was fingerprinted; the"
    echo "> lookups below assume \`php\` as this rig's default focus and may be"
    echo "> irrelevant. Prove the real product + version before trusting any of it."
  fi
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
  echo -e "## NVD\n\n_API unavailable/rate-limited at run time. Look up manually: ${NVD_URL}_\n" >> "$REPORT"
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
