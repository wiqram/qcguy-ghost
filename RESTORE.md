# Disaster recovery — restoring qcguy on a fresh host

Use this **only** when rebuilding qcguy on a brand-new host, or after the data disk
(`/dev/sdb1` → `/mnt/minikube-backups`) is wiped or lost. A normal redeploy on the
existing host needs none of this: MySQL's datadir persists on the `/mnt/qcguy-mysql`
hostPath and Ghost comes straight back with its content (verified by a live cluster
restart — see `docs/superpowers/specs/2026-06-30-sqlite-to-mysql-migration-design.md`).

The **infrastructure** (manifests + secrets) reproduces from `main`; the **data does
not** — it is never in git. This runbook restores the data.

## What is backed up, and where

Node path `/mnt` is a Docker bind to host `/mnt/minikube-backups/minikube-mnt`.

| Artifact | Location | In weekly + GCS backup? |
|---|---|---|
| MySQL **raw datadir** | `/mnt/qcguy-mysql/` | ✅ |
| MySQL **logical dumps** | `/mnt/qcguy-mysql-backups/qcguy-MM-DD-YY.sql.gz` | ✅ |
| Ghost **content** (images/themes) | `/mnt/qcguy-ghost/` (the content PVC) | ✅ |
| Vault secret (mysql config + creds) | `vault/ghost.secret.sops.env` (this repo) | ✅ repo is backed up; deploy pushes it to Vault |

Weekly archive — STEP0 `backup-minikube-mnt.sh`, Mondays ~05:00 Europe/London:
- Local: `/mnt/minikube-backups/private-cloud-MM-DD-YY.tgz`
- Off-site: `gs://private_cloud_backup/private-cloud-MM-DD-YY.tgz` (Coldline, GCP project `igtrader-296013`)

## Restore procedure

### 0. Obtain an archive (skip if the data disk survived)
```sh
GCLOUD=/home/cloud/google-cloud-sdk/bin/gcloud
"$GCLOUD" auth activate-service-account --key-file=/home/cloud/.gcp/step0-backup-key.json
"$GCLOUD" storage ls gs://private_cloud_backup/                 # pick the newest private-cloud-*.tgz
"$GCLOUD" storage cp gs://private_cloud_backup/private-cloud-<date>.tgz /tmp/
```

### 1. Restore qcguy's data dirs (in place)
The archive stores paths without the leading `/`. Extract just qcguy's dirs so you don't
clobber the other apps in the archive:
```sh
sudo tar xzf /tmp/private-cloud-<date>.tgz -C / \
  mnt/minikube-backups/minikube-mnt/qcguy-mysql \
  mnt/minikube-backups/minikube-mnt/qcguy-mysql-backups \
  mnt/minikube-backups/minikube-mnt/qcguy-ghost
ls /mnt/minikube-backups/minikube-mnt/qcguy-mysql       # InnoDB files present
```

### 2. Bring up the cluster and deploy qcguy
Start the cluster (STEP0 `start-scratch.sh`; `cluster-autostart.sh` reconciles health),
then trigger the qcguy Jenkins job — it runs `vaultSync` (writes the mysql config + creds
to `kv/qcguy/ghost`) then `kubectl apply -f compiled.yaml`:
```sh
curl -X POST 'https://<user:token>@jenkins.traderyolo.com/job/qcguy/build?token=qcguy'   # see STEP0/start-scratch.sh
```
The MySQL StatefulSet binds its hostPath PV to the restored `/mnt/qcguy-mysql` datadir, so
Ghost comes up **with the restored content** (this is the default, "Path A — raw datadir").
Verify:
```sh
kubectl -n qcguy get pods
curl -s -o /dev/null -w "%{http_code}\n" -H "X-Forwarded-Proto: https" https://www.qcguy.com/
```

### 3. Recovery path — restore from the logical dump
A raw-datadir tar of a *running* MySQL is not guaranteed crash-consistent. If MySQL won't
start cleanly, or you deployed onto an empty datadir, restore the last weekly logical dump
(crash-consistent, always restorable). Ghost must not write during the restore:
```sh
kubectl -n qcguy scale deployment/qcguy --replicas=0

# clean target (Ghost may have already created an empty schema on first boot)
kubectl -n qcguy exec mysql-0 -c mysql -- sh -c \
  'mysql -u root -p"$(cat /vault/secrets/mysql-root)" -e "DROP DATABASE IF EXISTS ghost; CREATE DATABASE ghost CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci; GRANT ALL ON ghost.* TO \"ghost\"@\"%\"; FLUSH PRIVILEGES;"'

# load the dump (it was made with --databases ghost, so it targets the ghost DB)
zcat /mnt/minikube-backups/minikube-mnt/qcguy-mysql-backups/qcguy-<date>.sql.gz \
  | kubectl -n qcguy exec -i mysql-0 -c mysql -- sh -c 'mysql -u root -p"$(cat /vault/secrets/mysql-root)"'

kubectl -n qcguy scale deployment/qcguy --replicas=1
```
Restore `/mnt/qcguy-ghost` (step 1) for the content files if it wasn't already.

### 4. Last resort — the legacy pre-MySQL SQLite backup
The one-time pre-migration snapshot is at `~/qcguy-migration-backup/<date>/ghost.db`
(+ `content.tgz`) on the operator's machine. **It is NOT in the weekly/off-site backup and
predates every post-migration change** — use only if all MySQL backups are gone. Reload it
into MySQL with the one-off Job `k8s/mysql-migration-job.yaml`
(`sqlite3-to-mysql --without-foreign-keys`); see
`docs/superpowers/plans/2026-06-30-sqlite-to-mysql-migration.md`.

## Verify after restore
- `kubectl top pod -n qcguy` — Ghost CPU idle; logs show **no** `getTime is not a function`.
- Row counts of `posts` / `members` / `emails` match the dump or last-known values.
- `https://www.qcguy.com/` and `/ghost/` return 200; spot-check a known post and member.

## Notes
- **Empty-MySQL first boot is a valid state** (verified): Ghost 6.47.0 runs its 301
  migrations, builds the full schema, seeds defaults, and serves a **blank** site. That is
  the "no backup, start clean" outcome — not an error.
- The restore relies on the MySQL password in `vault/ghost.secret.sops.env` (committed). It
  matches the recreated `ghost` user and a raw-datadir restore **unless the password was
  rotated after the backup** — in that case prefer the logical-dump path (step 3), which
  re-creates the user/grant against the current Vault password.
- Keep the Ghost image pinned to the version that produced the backup (`ghost:6.47.0` in
  `compiled.yaml`); a newer image could attempt migrations against restored data.
