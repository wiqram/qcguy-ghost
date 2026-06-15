# Vault secrets for this app (qcguy / Ghost CMS)

qcguy's Ghost config (`config.production.json`, including the mail password) is
stored in the shared **HashiCorp Vault**, not a Kubernetes `ConfigMap`. The Vault
Agent Injector renders it to `/vault/secrets/config.production.json` and the
container copies it to `/var/lib/ghost/config.production.json` at start.

- **Vault path:** `kv/qcguy/ghost` — one key `CONFIG_PRODUCTION_JSON_B64`
  (= base64 of the whole `config.production.json`).
- **Namespace:** `qcguy`  ·  **Role → policy:** `qcguy-role` → `qcguy-policy`
- **Owned here** in `vault/ghost.secret.sops.env` (SOPS+age encrypted).

## How to change the config / a secret

1. Edit `config/config.production.json` (the real Ghost config).
2. Re-encode + re-encrypt it into `vault/ghost.secret.sops.env`:
   ```sh
   printf 'CONFIG_PRODUCTION_JSON_B64=%s\n' "$(base64 -w0 config/config.production.json)" > vault/ghost.secret.env
   cd vault && sops -e ghost.secret.env > ghost.secret.sops.env && rm ghost.secret.env
   ```
3. Commit + push → the **qcguy** Jenkins job runs `vaultSync(app:'qcguy')` to
   refresh `kv/qcguy/ghost`, then rolls the deployment so the pod restarts with
   the new config.

Canonical workflow: https://github.com/wiqram/vault/blob/main/docs/adding-secrets.md

**Rules:** never commit the plaintext `config.production.json` *as a secret* (it
carries the mail password) — only the encrypted `vault/ghost.secret.sops.env` is
the source of truth Vault reads. A change is live only after the pod restarts (CI
does this).
