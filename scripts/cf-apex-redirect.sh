#!/usr/bin/env bash
#
# Cloudflare apex (qcguy.com) -> www redirect
# -------------------------------------------
# Fixes TODO.md item "Fix apex domain (qcguy.com) -> www".
# Adds a Dynamic Redirect (the API behind dashboard "Single Redirect") so the
# bare apex 301-redirects to https://www.qcguy.com, preserving path + query.
# The rule fires at Cloudflare's edge BEFORE origin SSL validation, so it
# bypasses the apex HTTP 526 ("Invalid SSL Certificate") even while the apex
# cert is still mis-configured.
#
# Usage:
#   export CF_API_TOKEN=...        # Zone > Config Rules:Edit  +  Zone:Read
#   ./scripts/cf-apex-redirect.sh  # defaults to Method A (safe append)
#   ./scripts/cf-apex-redirect.sh --overwrite   # Method B (replaces phase)
#
# NOTE: this is a bash script (arrays, read -d, pipefail). If launched with
# `sh script` it re-execs itself under bash automatically.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

set -euo pipefail

# --- 0) Config ---
# Do NOT hardcode the token here — pass it via env so it never lands in git:
#   export CF_API_TOKEN=...   # Zone > Config Rules:Edit + Zone:Read
CF_API_TOKEN="${CF_API_TOKEN:?set CF_API_TOKEN (Zone > Config Rules:Edit + Zone:Read)}"
ZONE_NAME="${ZONE_NAME:-qcguy.com}"
MODE="${1:-append}"   # "append" (safe) | "--overwrite" (replaces all dynamic-redirect rules)

AUTH=(-H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")

# --- 1) Look up the Zone ID from the domain (override with ZONE_ID=... if you prefer) ---
# NB: Cloudflare zone IDs are 32 LOWERCASE hex chars — an uppercase char => 7003 "invalid".
if [ -z "${ZONE_ID:-}" ]; then
  ZONE_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" "${AUTH[@]}" \
    | python3 -c "import sys,json;r=json.load(sys.stdin).get('result') or [];print(r[0]['id'] if r else '')")
fi
if [ -z "$ZONE_ID" ]; then
  echo "ERROR: could not resolve a zone id for ${ZONE_NAME} (check token has Zone:Read)." >&2
  exit 1
fi

# --- 2) The rule: apex host -> https://www, preserving path+query, 301 ---
read -r -d '' RULE <<'JSON' || true
{
  "action": "redirect",
  "action_parameters": {
    "from_value": {
      "status_code": 301,
      "target_url": { "expression": "concat(\"https://www.qcguy.com\", http.request.uri)" },
      "preserve_query_string": true
    }
  },
  "expression": "(http.host eq \"qcguy.com\")",
  "description": "apex to www",
  "enabled": true
}
JSON

# --- 3) Apply ---
if [ "$MODE" = "--overwrite" ]; then
  # Method B: REPLACES all rules in the dynamic-redirect phase. Use only if you have none.
  echo "Applying via OVERWRITE (replaces dynamic-redirect phase)..."
  curl -s -X PUT \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/rulesets/phases/http_request_dynamic_redirect/entrypoint" \
    "${AUTH[@]}" --data "{\"rules\":[${RULE}]}" | python3 -m json.tool
else
  # Method A: safe append — keeps any existing redirect rules.
  RULESET_ID=$(curl -s \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/rulesets/phases/http_request_dynamic_redirect/entrypoint" \
    "${AUTH[@]}" | python3 -c "import sys,json;print((json.load(sys.stdin).get('result') or {}).get('id',''))")
  if [ -n "$RULESET_ID" ]; then
    echo "Phase exists (ruleset ${RULESET_ID}) -> appending rule..."
    curl -s -X POST \
      "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/rulesets/${RULESET_ID}/rules" \
      "${AUTH[@]}" --data "$RULE" | python3 -m json.tool
  else
    echo "Phase missing -> creating entrypoint with rule..."
    curl -s -X PUT \
      "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/rulesets/phases/http_request_dynamic_redirect/entrypoint" \
      "${AUTH[@]}" --data "{\"rules\":[${RULE}]}" | python3 -m json.tool
  fi
fi

# --- 4) Verify (allow ~30s to propagate) ---
echo "Verify:"
echo '  curl -sS -o /dev/null -w "%{http_code} -> %{redirect_url}\n" https://qcguy.com/about/'
echo '  # expect: 301 -> https://www.qcguy.com/about/'
