# Design: Migrate qcguy Ghost from SQLite to MySQL 8

**Date:** 2026-06-30
**Status:** Approved (design) — pending spec review
**Author:** Claude Code + wiqram

## Background & motivation

The qcguy Ghost pod (`qcguy/qcguy-*`) idles at ~1.4 CPU. Root cause: Ghost 6.47.0's
email-analytics "fetch missing events" path reads the last job-run timestamp straight
from the DB and passes it to the Mailgun provider, which calls `options.begin.getTime()`.
On **SQLite**, `DATETIME` columns come back as **strings**, so `.getTime()` throws
`TypeError: options.begin.getTime is not a function`. The failed analytics job reschedules
immediately and hot-loops, burning CPU.

This only triggers because the site sends newsletters (an `email-analytics-*` job row
exists, so the `?? new Date(...)` fallback never fires). The sibling opened/non-opened
path has an explicit string→Date conversion ("SQLite compatibility"); the missing-events
path does not. **The bug is still present on Ghost `main`**, so upgrading Ghost alone does
not fix it.

**Fix chosen:** migrate the database from SQLite to MySQL 8. The `mysql2` driver returns
`DATETIME` columns as real `Date` objects, so `begin.getTime()` works and the crash loop
ends. MySQL is also Ghost's officially supported production backend (SQLite is dev-only).

## Hard requirements

- **No data loss.** Posts, pages, members/subscribers, newsletters, tags, settings, users,
  and email + analytics history must all survive. SQLite is kept intact as a rollback.
- **Clean rollback** to SQLite at any point in the migration.
- Integrate with the existing **Vault Agent + SOPS** secret workflow and the **Jenkins**
  `kubectl apply -f compiled.yaml` deploy flow.

## Environment (as observed)

- **Cluster:** single-node minikube (`minikube`, k8s v1.35.1).
- **Storage:** dynamic provisioner `standard` (`k8s.io/minikube-hostpath`) is the default —
  MySQL can use a normal PVC, no manual hostPath PV needed.
- **Current DB:** SQLite at `/var/lib/ghost/content/data/ghost.db` on PVC `qcguy-content-claim`.
- **Live data lives only in the pod's PVC.** The repo's `data/data/ghost.db` is stale (2022)
  and MUST NOT be used as the migration source.
- **Image:** `ghost:latest`, currently resolving to Ghost **6.47.0**.
- **Config delivery:** Vault Agent injects `config.production.json` from `kv/qcguy/ghost`;
  source of truth is `vault/ghost.secret.sops.env` (SOPS+age), pushed by Jenkins
  `vaultSync(app:'qcguy')` then `kubectl apply` + rollout.
- A `config/config.production.mysql.example.json` already exists (pointed at
  `mysql.default.svc.cluster.local`); we will instead run MySQL in the `qcguy` namespace.

## Architecture

### 1. MySQL 8 StatefulSet (in-cluster, `qcguy` namespace)

- **StatefulSet `mysql`** running `mysql:8.0`, single replica.
- **Headless/ClusterIP Service `mysql`** → DNS `mysql.qcguy.svc.cluster.local:3306`.
- **PVC** via `volumeClaimTemplates` on storageClass `standard`, ~2Gi.
- Database `ghost`, application user `ghost`. Charset `utf8mb4` (MySQL 8 default).
- Added to `compiled.yaml` so it deploys through the existing Jenkins flow.
- Modest resources (e.g. requests 250m/256Mi, limits 1/1Gi) — tune after observation.
- **Known gotcha:** if Ghost's `mysql2` connection is rejected by `caching_sha2_password`,
  set the user/auth plugin to `mysql_native_password`. Verify during cutover.

### 2. Secrets — Vault-injected single source of truth (chosen)

The MySQL password exists in two consumers: Ghost's `config.production.json` and the MySQL
StatefulSet. Both draw from the **same Vault bundle** — no plaintext in git, one value to rotate.

- New secret material lives in a SOPS-encrypted file in the repo's `vault/` dir
  (e.g. `vault/mysql.secret.sops.env`) and is pushed to Vault (e.g. `kv/qcguy/mysql`) by the
  Jenkins `vaultSync` stage, alongside the existing Ghost secret.
- The **MySQL StatefulSet** uses the **Vault Agent injector** (same `qcguy-role`) to render a
  credentials file consumed via MySQL's `MYSQL_ROOT_PASSWORD_FILE` / `MYSQL_PASSWORD_FILE`
  env vars.
- **Ghost's** `config.production.json` `database.connection.password` carries the same value
  via the existing `kv/qcguy/ghost` injection.
- **To verify in planning:** that `vaultSync(app:'qcguy')` supports pushing a second secret
  key, and that `qcguy-role`/`qcguy-policy` grants read on the new path. If `vaultSync` is
  single-secret only, fold the MySQL creds into the existing `kv/qcguy/ghost` bundle as
  additional keys rather than a new path.

### 3. Migration procedure (no-data-loss core)

Executed as an ordered runbook with a short maintenance window:

1. **Back up.** Copy the *live* `ghost.db` (+ `-wal`/`-shm`) and tar the full content dir out
   of the running pod to a safe location. Record SHA + row counts of key tables. SQLite is
   never deleted.
2. **Quiesce.** Scale the `qcguy` deployment to 0 replicas so no writes occur during the copy
   (consistent snapshot). Brief downtime acceptable (~100 visitors/day).
3. **Stand up MySQL.** Apply the StatefulSet/Service/Secret; wait for an empty `ghost` DB.
4. **Convert.** Run a one-off Kubernetes **Job** using `sqlite3-to-mysql`, mounting the content
   PVC (read) and connecting to MySQL, copying every table verbatim — including Ghost's
   `migrations` and `migrations_lock` tables so MySQL presents as already-migrated at 6.47.0.
5. **Verify.** Compare row counts SQLite vs MySQL for at least: `posts`, `members`,
   `members_stripe_customers`/`subscriptions`, `emails`, `users`, `tags`, `settings`.
   Counts must match before cutover.
6. **Cut over.** Update `config/config.production.json` `database` block to mysql (host
   `mysql.qcguy.svc.cluster.local`), **pin image `ghost:latest` → `ghost:6.47.0`** in
   `compiled.yaml`, re-encode/re-encrypt the Vault secret, commit, let Jenkins
   `vaultSync` + apply + rollout bring Ghost up against MySQL.
7. **Confirm.** Site and `/ghost` admin load; a known post, a member, and a newsletter are
   present; pod logs no longer show `options.begin.getTime`; `kubectl top pod` shows idle CPU.

### 4. Rollback

At any failure: revert the `database` block to `sqlite3` and image to `ghost:latest`,
redeploy. The untouched SQLite file on the PVC serves immediately. MySQL objects can be left
in place or torn down; no data was removed from SQLite.

### 5. Version pinning

`ghost:latest` → `ghost:6.47.0` in `compiled.yaml`. Two reasons: (a) the imported schema is at
6.47.0's migration state, so a newer image could attempt migrations against freshly-imported
data; (b) prevents surprise upgrades unrelated to this change.

## Out of scope (optional fast-follow)

- Ongoing `mysqldump` backup CronJob for MySQL. Recommended next, not in the critical path.
- Fixing the Ghost source bug upstream / carrying a patch (MySQL sidesteps it).

## Verification checklist (post-cutover)

- [ ] `kubectl top pod -n qcguy` CPU back to idle (~tens of millicores).
- [ ] `kubectl logs` shows no `options.begin.getTime is not a function`.
- [ ] `https://www.qcguy.com/` and `/ghost/` return 200 and render.
- [ ] Spot-check a known post, a known member, and a past newsletter exist.
- [ ] Row counts of key tables match the pre-migration SQLite snapshot.
- [ ] SQLite backup archived off-cluster.
