# Vault secrets for this app (qcguy / Ghost CMS)

qcguy's Ghost config (`config.production.json`, including the mail password) is
stored in the shared **HashiCorp Vault**, not a Kubernetes `ConfigMap`. The Vault
Agent Injector renders it to `/vault/secrets/config.production.json` and the
container copies it to `/var/lib/ghost/config.production.json` at start.

## Dev vs production

- **Dev:** use a local, **gitignored** `.env.development` / local
  `config.development.json` for Ghost. Dev never touches Vault.
- **Production:** the source of truth is `vault/ghost.secret.sops.env` in **this
  repo** (SOPS+age encrypted). Every prod deploy pushes it to `kv/qcguy/ghost`
  automatically — you never run `vault` by hand or touch the vault repo.

## Adding / changing a PRODUCTION secret (steps for Claude Code)

1. Edit the real config `config/config.production.json` (or whatever key changed).
2. Re-encode + re-encrypt it into `vault/ghost.secret.sops.env`:
   ```sh
   printf 'CONFIG_PRODUCTION_JSON_B64=%s\n' "$(base64 -w0 config/config.production.json)" > vault/ghost.secret.env
   cd vault && sops -e ghost.secret.env > ghost.secret.sops.env && rm ghost.secret.env
   ```
3. `git add vault/ghost.secret.sops.env && git commit && git push` (branch `main`).
4. The **qcguy** Jenkins deploy job runs `vaultSync(app:'qcguy')` → refreshes
   `kv/qcguy/ghost`, then rolls the deployment so the pod restarts with it.

## Reference

- **Vault path:** `kv/qcguy/ghost` — one key `CONFIG_PRODUCTION_JSON_B64`
  (= base64 of the whole `config.production.json`).
- **Namespace:** `qcguy`  ·  **Role → policy:** `qcguy-role` → `qcguy-policy`
- **Deploy branch:** `main`
- Canonical workflow: https://github.com/wiqram/vault/blob/main/docs/adding-secrets.md

**Rules:** never commit plaintext `config.production.json` *as a secret* (it
carries the mail password) — only the encrypted `vault/ghost.secret.sops.env` is
the source of truth Vault reads. A change is live only after the pod restarts
(CI does this).
