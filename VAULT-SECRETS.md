# Vault secrets for this app (qcguy)

> **Status: not yet onboarded to Vault.** This app does not yet have secrets in
> the shared HashiCorp Vault. This is a forward pointer so the workflow is known
> when onboarding happens.

When onboarded, this app's config/secrets will live at `kv/qcguy/<service>`
(namespace `qcguy`), injected into pods at `/vault/secrets/config` — no
Kubernetes `Secret`/`ConfigMap` manifests.

## Onboarding + adding secrets

Both are documented **canonically** here (see "Onboarding a new app"):
**https://github.com/wiqram/vault/blob/main/docs/adding-secrets.md**

Onboarding (one-time, in the `wiqram/vault` repo):

1. Namespace + `vault-secrets` SA for `qcguy`.
2. Least-privilege `qcguy-policy` scoped to **only** `kv/data/qcguy/*`
   (+ `kv/metadata/qcguy/*`) — never the wildcard `kv/*`.
3. `qcguy-role` bound to `bound_service_account_namespaces=qcguy`.
4. `scripts/setup-jenkins-approle.sh qcguy` for the scoped write identity.
5. Manifests under `apps/qcguy/<service>.env` / `.secret.sops.env`.
6. Injector annotations + a `vault-app=qcguy` label on the deployments.

After that, adding a secret is the standard **edit → `sops` → validate →
`--dry-run` → push → CI** loop, identical to every other app.

**Rules:** never commit plaintext `*.secret.env` — only the encrypted
`*.secret.sops.env`. A secret is not live until the consuming pod restarts.
