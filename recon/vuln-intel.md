# Vuln-intel — the rig's map of known holes

> **What this is:** the starting point the CAI agent consults *before* an authorized
> test. Two parts: (1) **where** known holes are looked up (the authoritative, living
> lists), and (2) a short **pinned** list of recent high-severity holes we always want
> on the radar. The actual fetching is done live by `recon/vuln-recon.sh` against the
> sources — do **not** maintain a hand-written CVE list here; it rots.

> **Authorization:** querying CVE databases is public data and always fine.
> *Fingerprinting a target* (sending traffic to the customer's host) requires written
> scope. See `../README.md` → "Important".

---

## 1. "Is there a dedicated list?" — yes, these are the source of truth

Not one list, but a handful of authoritative, **living** sources. `vuln-recon.sh`
pulls from them automatically. Ranked by how directly they answer "which known holes
apply to this target":

| Source | What it is | Why it's first choice | Lookup |
|--------|-----------|-----------------------|--------|
| **CISA KEV** | Known Exploited Vulnerabilities — the catalog of holes *actually exploited in the wild* | This is "the list". Everything here is proven exploited → top priority | JSON feed, see below |
| **NVD** | NIST National Vulnerability Database — every CVE with CVSS + CPE version ranges | Look up *exact product + version* and get all known CVEs | API 2.0, see below |
| **Exploit-DB / searchsploit** | Public PoCs / exploits, indexed | Is there a ready PoC for this version? Offline via `searchsploit` | `searchsploit <product> <version>` |
| **GitHub Security Advisories / OSV** | Holes at the package/dependency level (Composer, npm, pip …) | For app dependencies, not just the server | osv.dev API |
| **PHP release advisories** | PHP's own security releases | Source of truth for which PHP versions are fixed | php.net/ChangeLog-8.php |
| **Patchstack** | WordPress/PHP ecosystem (plugins/themes) | WP stack: plugin holes dominate the attack surface | patchstack.com/database |

### Lookup endpoints (what `vuln-recon.sh` hits)

```
# CISA KEV — the full catalog as JSON (source of truth for actively exploited holes)
https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json

# NVD API 2.0 — CVEs covering a specific version (CPE match)
https://services.nvd.nist.gov/rest/json/cves/2.0?virtualMatchString=cpe:2.3:a:php:php:<version>
#   optional NVD_API_KEY raises the rate limit from 5 to 50 calls / 30 s

# OSV — package-level holes
https://api.osv.dev/v1/query

# Exploit-DB offline
searchsploit <product> <version>
```

---

## 2. Pinned — recent high-severity holes we always check

> Short and hand-picked. Dates are absolute. `vuln-recon.sh` confirms status live —
> this list only exists so we don't *forget* them. Add new ones on top; drop them once
> they're old news and well covered by the living feeds.

### PHP "php2shell" — CVE-2026-109618 & CVE-2026-109619  *(added 2026-10-24)*

- **What:** two critical, **unauthenticated RCE** holes in PHP core. Nicknamed
  *php2shell*. CVSS v4.0 **9.2** both.
- **Affects:** every PHP setup that serves web — mod_php (highest risk per PHP),
  PHP-FPM, php-cgi, FrankenPHP, LiteSpeed.
- **Fixed in:** PHP **8.5.12 / 8.4.27 / 8.3.36 / 8.2.35** (emergency release 2026-10-21).
  Branches older than 8.2 get *no* fix → an 8.1/7.x host is exposed by definition.
- **Timeline:** details leaked 2026-10-20 before coordinated disclosure; Amazon
  Threat Intelligence saw exploitation attempts as early as 2026-10-17 (0-day). CISA
  alert 10-21.
- **Partial mitigation (not a full fix):** `session.upload_progress.enabled = 0`
  closes known paths for the second hole, but not every variant. Updating is the only
  complete fix. Cloudflare has WAF rules for the known vectors.
- **For a test:** when a target runs PHP < the fixed versions → flag as
  **critical, likely exploitable**. Verify the version via `Server`/`X-Powered-By`
  or `phpinfo`, don't guess. Do not write an exploitation payload in the report —
  point at the version and the remediation (patch).

Sources:
- CISA: https://www.cisa.gov/news-events/alerts/2026/10/21/critical-vulnerabilities-php-require-immediate-patching
- Unit 42: https://unit42.paloaltonetworks.com/cve-2026-109618-cve-2026-109619/
- Help Net Security: https://www.helpnetsecurity.com/2026/10/21/php2shell-php-vulnerabilities-patched-cve-2026-109618-cve-2026-109619/
- Patchstack: https://patchstack.com/articles/php-major-vulnerability-alert-10-2026/

---

## 3. Methodology — the order the agent should follow

1. **Fingerprint** the target (within scope): `Server`, `X-Powered-By`, versions,
   frameworks, plugins. Never guess a version — prove it.
2. **Pull known holes BEFORE active testing:** run `recon/vuln-recon.sh <target>`. It
   looks up CISA KEV + NVD (+ searchsploit/OSV) for the fingerprinted product and
   version, and writes a brief.
3. **Prioritize:** KEV hits (proven exploited) first, then CVSS-critical with a known
   PoC, then the rest. Always match against the *actual* version — not every CVE for
   "PHP" applies to this exact one.
4. **Then test — only within written scope.** Use the brief to steer the test toward
   what is actually relevant, not to blindly run everything.
5. **Report** findings against controls/versions. No exploitation payloads in the
   report; point at the hole, the affected version, and the remediation (usually: patch
   to the fixed version).
