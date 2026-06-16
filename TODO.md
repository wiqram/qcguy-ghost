# TODO

## [x] Fix apex domain (`qcguy.com`) → `www` so all pages serve via the menu/bookmarks

**Status:** ✅ RESOLVED 2026-06-16 (identified & fixed same day) · Severity was: medium

### Resolution (what was done)
Added a Cloudflare **Single Redirect / Dynamic Redirect** rule on zone `qcguy.com`
(id `b8cc33a4a17924e5108ff1ccfcc54a57`) via [`scripts/cf-apex-redirect.sh`]
(scripts/cf-apex-redirect.sh):

- Match: `(http.host eq "qcguy.com")`
- Then: dynamic redirect → `concat("https://www.qcguy.com", http.request.uri)`, status `301`
- Fires at the edge before origin SSL validation, so it bypasses the apex 526.

**Verified live 2026-06-16:**
```
https://qcguy.com/about/  -> 301 -> https://www.qcguy.com/about/  -> 200
https://qcguy.com/        -> 301 -> https://www.qcguy.com/
```
The apex now redirects instead of returning 526; menu links and apex bookmarks resolve.

**Gotchas for next time (kept for reference):**
- Cloudflare zone IDs are 32 **lowercase** hex chars — an uppercase char gives API
  error `7003 "object identifier is invalid"`. Let the script look the id up by name.
- The API token needs **Zone > Config Rules:Edit** (Dynamic Redirect) **+ Zone:Read**;
  a Zone:Read-only token returns `"request is not authorized"` on the write.
- Never hardcode the token in the script — pass `CF_API_TOKEN` via env (it's a git repo).

### Optional follow-up (not blocking — site works)
Part 2 below was **not** applied: the Ghost nav links still point at `http://qcguy.com/...`.
They now work fine *through* the new redirect (extra 301 hop), so this is cosmetic only —
do it whenever convenient to drop the redundant hop.

<details><summary>Original problem & full fix notes (archived)</summary>

**Status:** Open · Identified 2026-06-16 · Severity: medium (site works on `www`, breaks on apex)

### Problem
Pages are served only on the canonical host `https://www.qcguy.com` (all 28 sitemap URLs
return 200). The bare apex `qcguy.com` over HTTPS returns **HTTP 526 (Cloudflare "Invalid
SSL Certificate")** for every path — `http://qcguy.com/... → 301 → https://qcguy.com/... → 526`.

The Ghost nav menu links point at the broken apex, so clicking About / Contact /
Data & privacy lands visitors on the 526 error page even though the underlying pages are healthy:

```
settings.navigation:           { url: 'http://qcguy.com/about/',   label: 'About' }
settings.secondary_navigation: { url: 'http://qcguy.com/privacy/', label: 'Data & privacy' }
                               { url: 'http://qcguy.com/contact/', label: 'Contact' }
```

It is host-wiring, not a per-page or pod issue — the Ghost pod and DB are fine
(about page = published, public, type=page).

### Fix (two parts)

1. **Cloudflare — add a Redirect Rule (apex → www).**
   Ready-to-run API script: [`scripts/cf-apex-redirect.sh`](scripts/cf-apex-redirect.sh)
   ```bash
   export CF_API_TOKEN=...        # Zone > Config Rules:Edit + Zone:Read
   ./scripts/cf-apex-redirect.sh  # safe append (or: --overwrite)
   ```
   Equivalent dashboard path — Rules → Redirect Rules → Create → Single Redirect:
   - Match:  `(http.host eq "qcguy.com")`
   - Then:   Dynamic redirect, expression `concat("https://www.qcguy.com", http.request.uri)`
   - Status: `301`
   - (Fires at the edge before origin SSL validation, so it bypasses the 526.)
   - Also confirm SSL/TLS → Edge Certificates: Universal SSL Active and covers
     `qcguy.com` + `*.qcguy.com`.

2. **Ghost Admin → Settings → Navigation — switch links to relative paths.**
   - `http://qcguy.com/about/`   → `/about/`
   - `http://qcguy.com/privacy/` → `/privacy/`
   - `http://qcguy.com/contact/` → `/contact/`
   (Relative URLs resolve against the configured site `url` = `https://www.qcguy.com`,
   so they can never point at the apex again.)

### Verify after applying
```bash
curl -sS -o /dev/null -w "%{http_code} -> %{redirect_url}\n" https://qcguy.com/about/
#   expect: 301 -> https://www.qcguy.com/about/
curl -sS https://www.qcguy.com/ | grep -o 'href="[^"]*about[^"]*"'
#   expect: href="https://www.qcguy.com/about/"
```

</details>
