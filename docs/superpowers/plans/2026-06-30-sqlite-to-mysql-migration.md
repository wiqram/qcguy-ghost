# SQLite → MySQL 8 Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the qcguy Ghost CMS database from SQLite to an in-cluster MySQL 8 StatefulSet with zero data loss, ending the email-analytics CPU hot-loop.

**Architecture:** Stand up MySQL 8 as a StatefulSet in the `qcguy` namespace (credentials injected by the existing Vault Agent from the `kv/qcguy/ghost` bundle). Back up live SQLite, quiesce Ghost, copy every table verbatim into MySQL with `sqlite3-to-mysql`, then cut Ghost's config over to MySQL and pin the image to `ghost:6.47.0`. SQLite is never deleted — rollback is a one-line config revert.

**Tech Stack:** Kubernetes (minikube, single node), MySQL 8.0, Ghost 6.47.0, HashiCorp Vault Agent injector, SOPS+age, Jenkins, `sqlite3-to-mysql` (Python).

---

## Operating notes (read before starting)

- **This is a runbook, not a code feature** — "tests" are verification commands with expected output. Do not skip them; they are the no-data-loss guarantee.
- **Source of truth for data is the LIVE pod PVC** (`qcguy-content-claim`), NOT the stale `data/data/ghost.db` in this repo.
- **Deploy mechanics during the window:** apply manifests with direct `kubectl apply` for control. Only **merge the branch to `main` at the very end**, so Jenkins (`vaultSync` + apply + rollout) reconciles to the already-verified state instead of racing the migration.
- **Maintenance window:** Ghost is offline from Task 4 (scale to 0) until Task 6 (cutover up). Expect a few minutes. The user has approved this.
- **Branch:** all work happens on `feat/mysql-migration` (already created and holding the design doc).
- **Rollback at any point:** see Task 8. SQLite on the PVC is untouched throughout.

---

## File structure

- **Modify** `config/config.production.json` — swap `database` block sqlite3 → mysql (Task 6).
- **Modify** `compiled.yaml` — add MySQL StatefulSet + Service + headless Service; pin Ghost image to `ghost:6.47.0` (Tasks 2 + 6).
- **Create** `vault/ghost.secret.env` (transient, gitignored, deleted after encrypt) — carries `CONFIG_PRODUCTION_JSON_B64` + new `MYSQL_ROOT_PASSWORD` + `MYSQL_PASSWORD` (Tasks 1 + 6).
- **Modify** `vault/ghost.secret.sops.env` — re-encrypted bundle with the MySQL keys (Tasks 1 + 6).
- **Create** `k8s/mysql-migration-job.yaml` — one-off Job running `sqlite3-to-mysql` (Task 5).
- **Reference only** `config/config.production.mysql.example.json` — existing example; superseded by the real change in Task 6.

---

## Task 1: Generate MySQL credentials and add them to the Vault bundle

**Files:**
- Create (transient): `vault/ghost.secret.env`
- Modify: `vault/ghost.secret.sops.env`

- [ ] **Step 1: Generate a strong MySQL password and capture it**

```bash
cd /home/cloud/Ideaprojects/qcguy-ghost
MYSQL_PW="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
echo "Generated MySQL password (save to your password manager): $MYSQL_PW"
```

Expected: a 32-char alphanumeric string printed. Record it; it is reused in Tasks 5 and 6.

- [ ] **Step 2: Decrypt the current bundle to plaintext**

```bash
cd vault
sops -d ghost.secret.sops.env > ghost.secret.env
grep -c CONFIG_PRODUCTION_JSON_B64 ghost.secret.env
```

Expected: prints `1` (the existing key is present). `ghost.secret.env` now holds the current plaintext.

- [ ] **Step 3: Append the MySQL credential keys**

```bash
# still in vault/
printf 'MYSQL_ROOT_PASSWORD=%s\n' "$MYSQL_PW" >> ghost.secret.env
printf 'MYSQL_PASSWORD=%s\n'      "$MYSQL_PW" >> ghost.secret.env
grep -E '^MYSQL_(ROOT_)?PASSWORD=' ghost.secret.env
```

Expected: both `MYSQL_ROOT_PASSWORD=...` and `MYSQL_PASSWORD=...` lines print. (Root and app password are intentionally the same value here for simplicity on a single-tenant DB; split them if you prefer.)

- [ ] **Step 4: Re-encrypt and remove plaintext**

```bash
# still in vault/
sops -e ghost.secret.env > ghost.secret.sops.env && rm ghost.secret.env
sops -d ghost.secret.sops.env | grep -c MYSQL_PASSWORD
```

Expected: prints `1` — confirms the encrypted bundle round-trips and contains the new key. `ghost.secret.env` is deleted.

- [ ] **Step 5: Commit the encrypted bundle**

```bash
cd /home/cloud/Ideaprojects/qcguy-ghost
git add vault/ghost.secret.sops.env
git commit -m "feat(vault): add MySQL credentials to qcguy secret bundle"
```

> Do NOT push yet — pushing triggers Jenkins. We push/merge only at Task 7.

---

## Task 2: Add the MySQL 8 StatefulSet to compiled.yaml and deploy it alongside Ghost

Ghost stays on SQLite during this task; we are only standing up an (empty) MySQL next to it.

**Files:**
- Modify: `compiled.yaml` (append MySQL resources)

- [ ] **Step 1: Append the MySQL Service + StatefulSet to `compiled.yaml`**

Add the following at the end of `compiled.yaml` (after the Ghost Deployment). The MySQL pod reuses the `vault-secrets` ServiceAccount and the same Vault role to render its root/app passwords from `kv/qcguy/ghost` into files, which the official image consumes via `*_FILE` env vars.

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: qcguy
  labels:
    app: mysql
spec:
  clusterIP: None          # headless — stable DNS mysql.qcguy.svc.cluster.local
  selector:
    app: mysql
  ports:
    - port: 3306
      targetPort: 3306
      name: mysql
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: qcguy
  labels:
    app: mysql
spec:
  serviceName: mysql
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
      annotations:
        # Render the MySQL passwords from the same Vault bundle Ghost uses.
        vault.hashicorp.com/agent-inject: 'true'
        vault.hashicorp.com/role: 'qcguy-role'
        vault.hashicorp.com/agent-pre-populate-only: 'true'
        vault.hashicorp.com/agent-inject-secret-mysql-root: 'kv/qcguy/ghost'
        vault.hashicorp.com/agent-inject-template-mysql-root: |
          {{- with secret "kv/qcguy/ghost" -}}{{ .Data.data.MYSQL_ROOT_PASSWORD }}{{- end -}}
        vault.hashicorp.com/agent-inject-secret-mysql-pass: 'kv/qcguy/ghost'
        vault.hashicorp.com/agent-inject-template-mysql-pass: |
          {{- with secret "kv/qcguy/ghost" -}}{{ .Data.data.MYSQL_PASSWORD }}{{- end -}}
    spec:
      serviceAccountName: vault-secrets
      containers:
        - name: mysql
          image: mysql:8.0
          # Force native auth so Ghost's mysql2 driver can never be rejected by
          # caching_sha2_password mid-cutover.
          args: ["--default-authentication-plugin=mysql_native_password"]
          env:
            - name: MYSQL_ROOT_PASSWORD_FILE
              value: /vault/secrets/mysql-root
            - name: MYSQL_PASSWORD_FILE
              value: /vault/secrets/mysql-pass
            - name: MYSQL_DATABASE
              value: ghost
            - name: MYSQL_USER
              value: ghost
          ports:
            - containerPort: 3306
              name: mysql
          resources:
            requests:
              cpu: "250m"
              memory: "384Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
          readinessProbe:
            exec:
              command: ["sh", "-c", "mysqladmin ping -h 127.0.0.1 -u root -p\"$(cat /vault/secrets/mysql-root)\" --silent"]
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          volumeMounts:
            - name: mysql-data
              mountPath: /var/lib/mysql
  volumeClaimTemplates:
    - metadata:
        name: mysql-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: standard
        resources:
          requests:
            storage: 2Gi
```

- [ ] **Step 2: Validate the YAML parses**

```bash
kubectl apply --dry-run=client -f compiled.yaml
```

Expected: every resource prints `... (dry run)` with no errors (Namespace, ServiceAccount, both Services, PV, PVC, Deployment, mysql Service, mysql StatefulSet).

- [ ] **Step 3: Apply (creates MySQL; Ghost Deployment unchanged)**

```bash
kubectl apply -f compiled.yaml
```

Expected: `statefulset.apps/mysql created`, `service/mysql created`, others `unchanged` / `configured`.

- [ ] **Step 4: Wait for MySQL to become Ready**

```bash
kubectl -n qcguy rollout status statefulset/mysql --timeout=180s
kubectl -n qcguy get pod mysql-0
```

Expected: `partitioned roll out complete: 1 ... ready` and `mysql-0  2/2  Running` (2/2 = mysql + vault-agent sidecar; with `agent-pre-populate-only` it may show `1/1` after the init container finishes — either is fine as long as Running and Ready).

- [ ] **Step 5: Verify the empty `ghost` database exists and the app user can connect**

```bash
kubectl -n qcguy exec mysql-0 -c mysql -- \
  sh -c 'mysql -u ghost -p"$(cat /vault/secrets/mysql-pass)" -e "SHOW DATABASES;"'
```

Expected: a table listing including `ghost`. (If this command needs approval to exec, approve it — it is read-only.)

- [ ] **Step 6: Commit the manifest change**

```bash
git add compiled.yaml
git commit -m "feat(k8s): add MySQL 8 StatefulSet for qcguy Ghost"
```

---

## Task 3: Back up the live SQLite database (no-data-loss gate)

**Files:** none (produces local backup artifacts)

- [ ] **Step 1: Identify the running Ghost pod**

```bash
POD=$(kubectl -n qcguy get pod -l app=qcguy -o jsonpath='{.items[0].metadata.name}')
echo "$POD"
```

Expected: prints the current `qcguy-...` pod name.

- [ ] **Step 2: Copy the live SQLite DB and content out of the pod**

```bash
mkdir -p ~/qcguy-migration-backup/$(date +%F)
BK=~/qcguy-migration-backup/$(date +%F)
kubectl -n qcguy cp "$POD":/var/lib/ghost/content/data/ghost.db "$BK/ghost.db" -c qcguy
kubectl -n qcguy exec "$POD" -c qcguy -- tar czf - -C /var/lib/ghost content > "$BK/content.tgz"
ls -la "$BK"
```

Expected: `ghost.db` (~1.5MB) and `content.tgz` present in the backup dir. (Approve the `cp`/`exec` if prompted — these are read-only.)

- [ ] **Step 3: Record SQLite row counts for every table (the comparison baseline)**

```bash
BK=~/qcguy-migration-backup/$(date +%F)
sqlite3 "$BK/ghost.db" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" \
| while read t; do printf '%s %s\n' "$t" "$(sqlite3 "$BK/ghost.db" "SELECT COUNT(*) FROM \"$t\";")"; done \
| tee "$BK/sqlite-rowcounts.txt"
```

Expected: a `table count` listing (includes `posts`, `members`, `users`, `tags`, `settings`, `emails`, `migrations`, etc.) saved to `sqlite-rowcounts.txt`. If `sqlite3` is not installed locally: `sudo apt-get install -y sqlite3`.

- [ ] **Step 4: Verify the backup DB is readable and non-empty**

```bash
BK=~/qcguy-migration-backup/$(date +%F)
sqlite3 "$BK/ghost.db" "SELECT COUNT(*) FROM posts;"
```

Expected: a number ≥ 1 (the site has posts). If this errors or returns 0, STOP — do not proceed; investigate the backup.

---

## Task 4: Quiesce Ghost (start of maintenance window)

**Files:** none

- [ ] **Step 1: Scale the Ghost Deployment to 0 to stop all DB writes**

```bash
kubectl -n qcguy scale deployment/qcguy --replicas=0
kubectl -n qcguy rollout status deployment/qcguy --timeout=60s
kubectl -n qcguy get pods -l app=qcguy
```

Expected: `deployment "qcguy" successfully rolled out` and `No resources found` / zero qcguy app pods. The PVC `qcguy-content-claim` is now free to mount elsewhere.

- [ ] **Step 2: Confirm the site is in maintenance (expected, brief)**

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://www.qcguy.com/ || true
```

Expected: a 5xx/timeout (Ghost is down). This is the intended window; proceed promptly.

---

## Task 5: Convert SQLite → MySQL with a one-off Job and verify row counts

**Files:**
- Create: `k8s/mysql-migration-job.yaml`

- [ ] **Step 1: Write the migration Job manifest**

This Job mounts the freed content PVC (read) to reach `ghost.db`, gets the MySQL password from Vault, installs `sqlite3-to-mysql`, and copies every table into MySQL.

```yaml
# k8s/mysql-migration-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ghost-sqlite-to-mysql
  namespace: qcguy
spec:
  backoffLimit: 0          # do not silently retry a partial load
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: 'true'
        vault.hashicorp.com/role: 'qcguy-role'
        vault.hashicorp.com/agent-pre-populate-only: 'true'
        vault.hashicorp.com/agent-inject-secret-mysql-pass: 'kv/qcguy/ghost'
        vault.hashicorp.com/agent-inject-template-mysql-pass: |
          {{- with secret "kv/qcguy/ghost" -}}{{ .Data.data.MYSQL_PASSWORD }}{{- end -}}
    spec:
      serviceAccountName: vault-secrets
      restartPolicy: Never
      volumes:
        - name: content
          persistentVolumeClaim:
            claimName: qcguy-content-claim
      containers:
        - name: migrate
          image: python:3.12-slim
          command: ["/bin/sh","-c"]
          args:
            - |
              set -e
              pip install --no-cache-dir 'sqlite-to-mysql' >/tmp/pip.log 2>&1 || pip install --no-cache-dir 'sqlite3-to-mysql'
              MYSQL_PW="$(cat /vault/secrets/mysql-pass)"
              sqlite3mysql \
                --sqlite-file /content/data/ghost.db \
                --mysql-database ghost \
                --mysql-user ghost \
                --mysql-password "$MYSQL_PW" \
                --mysql-host mysql.qcguy.svc.cluster.local \
                --mysql-port 3306 \
                --mysql-charset utf8mb4 \
                --mysql-collation utf8mb4_general_ci
              echo "MIGRATION_DONE"
          volumeMounts:
            - name: content
              mountPath: /content
              readOnly: true
```

> Note: the PyPI package is `sqlite3-to-mysql` and installs the `sqlite3mysql` CLI. The `pip install` line tries both spellings to be safe.

- [ ] **Step 2: Run the Job and follow its logs**

```bash
kubectl apply -f k8s/mysql-migration-job.yaml
kubectl -n qcguy wait --for=condition=complete job/ghost-sqlite-to-mysql --timeout=300s &
kubectl -n qcguy logs -f job/ghost-sqlite-to-mysql -c migrate
```

Expected: progress output from `sqlite3mysql` per table, ending with `MIGRATION_DONE` and the Job reaching `Complete`. If it errors, STOP and go to Task 8 (rollback) — MySQL can be wiped and retried; SQLite is untouched.

- [ ] **Step 3: Dump MySQL row counts for every table**

```bash
kubectl -n qcguy exec mysql-0 -c mysql -- sh -c '
  PW="$(cat /vault/secrets/mysql-pass)";
  for t in $(mysql -N -u ghost -p"$PW" -e "SELECT table_name FROM information_schema.tables WHERE table_schema='\''ghost'\'' ORDER BY table_name;"); do
    c=$(mysql -N -u ghost -p"$PW" -e "SELECT COUNT(*) FROM ghost.\`$t\`;");
    echo "$t $c";
  done' | tee ~/qcguy-migration-backup/$(date +%F)/mysql-rowcounts.txt
```

Expected: a `table count` listing saved to `mysql-rowcounts.txt`.

- [ ] **Step 4: Diff SQLite vs MySQL counts — the no-data-loss assertion**

```bash
BK=~/qcguy-migration-backup/$(date +%F)
diff <(sort "$BK/sqlite-rowcounts.txt") <(sort "$BK/mysql-rowcounts.txt") && echo "ROW COUNTS MATCH"
```

Expected: `ROW COUNTS MATCH` with no diff output. If any table differs, STOP — investigate before cutover. (A benign exception can be Ghost-internal lock tables like `migrations_lock`; confirm any difference is explainable and not a content table such as `posts`/`members`/`emails`. If unsure, treat as a failure and roll back.)

- [ ] **Step 5: Delete the completed Job (frees the PVC)**

```bash
kubectl -n qcguy delete job ghost-sqlite-to-mysql
```

Expected: `job.batch "ghost-sqlite-to-mysql" deleted`.

- [ ] **Step 6: Commit the Job manifest for the record**

```bash
git add k8s/mysql-migration-job.yaml
git commit -m "feat(k8s): one-off SQLite->MySQL migration Job"
```

---

## Task 6: Cut Ghost over to MySQL

**Files:**
- Modify: `config/config.production.json`
- Modify: `compiled.yaml` (pin image)
- Modify: `vault/ghost.secret.sops.env` (re-encode config with MySQL block)

- [ ] **Step 1: Switch the database block to MySQL**

Replace the `database` block in `config/config.production.json` so it reads exactly:

```json
  "database": {
    "client": "mysql",
    "connection": {
      "host": "mysql.qcguy.svc.cluster.local",
      "port": 3306,
      "user": "ghost",
      "password": "PUT_THE_MYSQL_PW_FROM_TASK_1_HERE",
      "database": "ghost"
    },
    "pool": {
      "min": 2,
      "max": 10
    }
  },
```

Use the exact password generated in Task 1, Step 1.

- [ ] **Step 2: Pin the Ghost image in `compiled.yaml`**

Change the Ghost container image line:

```yaml
          image: ghost:6.47.0
```

(from `image: ghost:latest`) so the imported 6.47.0 schema is never hit by a newer image's migrations.

- [ ] **Step 3: Re-encode the config into the Vault bundle**

```bash
cd /home/cloud/Ideaprojects/qcguy-ghost
sops -d vault/ghost.secret.sops.env > vault/ghost.secret.env
# replace the CONFIG_PRODUCTION_JSON_B64 line with the new base64 of the edited config
NEWB64="$(base64 -w0 config/config.production.json)"
grep -v '^CONFIG_PRODUCTION_JSON_B64=' vault/ghost.secret.env > vault/ghost.secret.env.tmp
printf 'CONFIG_PRODUCTION_JSON_B64=%s\n' "$NEWB64" >> vault/ghost.secret.env.tmp
mv vault/ghost.secret.env.tmp vault/ghost.secret.env
cd vault && sops -e ghost.secret.env > ghost.secret.sops.env && rm ghost.secret.env && cd ..
sops -d vault/ghost.secret.sops.env | grep -o '"client": *"mysql"'
```

Expected: prints `"client": "mysql"` — confirms the encrypted bundle now carries the MySQL config. (The `MYSQL_*` keys from Task 1 are preserved because we only replaced the one CONFIG line.)

- [ ] **Step 4: Push the Vault secret to the live Vault (manual, mirrors the Jenkins vaultSync)**

> The clean path is to let Jenkins do this on merge (Task 7). To bring Ghost up inside the window without waiting for CI, push the secret now using the same `vaultSync` tooling, or apply directly. If you have `vault` CLI access:

```bash
# the Vault Agent reads kv/qcguy/ghost; vaultSync(app:'qcguy') normally writes it.
# Manual equivalent (run from an authenticated context):
vault kv put kv/qcguy/ghost \
  CONFIG_PRODUCTION_JSON_B64="$(base64 -w0 config/config.production.json)" \
  MYSQL_ROOT_PASSWORD="<pw>" MYSQL_PASSWORD="<pw>"
```

Expected: `Success! Data written to: kv/qcguy/ghost`. If you do not have direct Vault access, skip to Task 7 and let Jenkins push it; Ghost stays down until then.

- [ ] **Step 5: Restore the image and scale Ghost back up**

```bash
kubectl apply -f compiled.yaml          # applies the ghost:6.47.0 image change
kubectl -n qcguy scale deployment/qcguy --replicas=1
kubectl -n qcguy rollout status deployment/qcguy --timeout=240s
```

Expected: rollout completes; a new `qcguy-...` pod reaches `1/1 Running`. (The Deployment spec still has `replicas: 1` in git; the scale-to-0 was a live override now superseded.)

- [ ] **Step 6: Commit the cutover changes**

```bash
git add config/config.production.json compiled.yaml vault/ghost.secret.sops.env
git commit -m "feat: cut Ghost over to MySQL 8 and pin image to 6.47.0"
```

---

## Task 7: Post-cutover verification and GitOps reconcile

**Files:** none (then merge to `main`)

- [ ] **Step 1: Confirm Ghost connected to MySQL and the crash loop is gone**

```bash
POD=$(kubectl -n qcguy get pod -l app=qcguy -o jsonpath='{.items[0].metadata.name}')
kubectl -n qcguy logs "$POD" -c qcguy --tail=80 | grep -i -E "mysql|getTime|database" || echo "no matching lines"
```

Expected: no `options.begin.getTime is not a function` lines. Ghost boot logs reference MySQL (or simply no DB errors).

- [ ] **Step 2: Confirm CPU is back to idle (the original goal)**

```bash
sleep 60
kubectl top pod -n qcguy
```

Expected: the `qcguy-...` pod CPU is now tens of millicores, not ~1400m.

- [ ] **Step 3: Confirm the public site and admin render**

```bash
curl -s -o /dev/null -w "site:%{http_code}\n" -H "X-Forwarded-Proto: https" https://www.qcguy.com/
curl -s -o /dev/null -w "admin:%{http_code}\n" https://www.qcguy.com/ghost/
```

Expected: `site:200` and `admin:200` (or `admin:302` to sign-in).

- [ ] **Step 4: Spot-check content survived (post, member, newsletter)**

```bash
kubectl -n qcguy exec mysql-0 -c mysql -- sh -c '
  PW="$(cat /vault/secrets/mysql-pass)";
  mysql -u ghost -p"$PW" -e "
    SELECT (SELECT COUNT(*) FROM ghost.posts)   AS posts,
           (SELECT COUNT(*) FROM ghost.members) AS members,
           (SELECT COUNT(*) FROM ghost.newsletters) AS newsletters,
           (SELECT COUNT(*) FROM ghost.emails)  AS emails;"'
```

Expected: counts match the SQLite baseline from Task 3, Step 3. Also click through a known post and the members page in a browser if convenient.

- [ ] **Step 5: Reconcile GitOps — merge to `main` so Jenkins becomes source of truth**

```bash
git checkout main
git merge --no-ff feat/mysql-migration -m "Merge: migrate qcguy Ghost from SQLite to MySQL 8"
git push origin main
```

Expected: Jenkins `qcguy` job runs `vaultSync(app:'qcguy')` (pushes the bundle — idempotent if Task 6 Step 4 already did) and `kubectl apply` + rollout (no-op since already applied). The site stays up.

- [ ] **Step 6: Archive the backup off-cluster**

Copy `~/qcguy-migration-backup/<date>/` (holding `ghost.db`, `content.tgz`, both rowcount files) to durable storage. Keep it at least until you are confident in MySQL (e.g. a week).

---

## Task 8: Rollback procedure (only if a prior task fails)

**Files:** revert working-tree changes

Use this if Task 5 verification fails or Ghost won't boot on MySQL. SQLite on the PVC was never modified.

- [ ] **Step 1: Revert config and image to SQLite**

```bash
git checkout -- config/config.production.json compiled.yaml   # if not yet committed
# OR if already committed in Task 6:
git revert --no-edit <task6-commit-sha>
```

The `database` block returns to `client: sqlite3`, image to `ghost:latest`.

- [ ] **Step 2: Re-encode the SQLite config into Vault and push**

```bash
sops -d vault/ghost.secret.sops.env > vault/ghost.secret.env
NEWB64="$(base64 -w0 config/config.production.json)"
grep -v '^CONFIG_PRODUCTION_JSON_B64=' vault/ghost.secret.env > t && printf 'CONFIG_PRODUCTION_JSON_B64=%s\n' "$NEWB64" >> t && mv t vault/ghost.secret.env
cd vault && sops -e ghost.secret.env > ghost.secret.sops.env && rm ghost.secret.env && cd ..
vault kv put kv/qcguy/ghost CONFIG_PRODUCTION_JSON_B64="$NEWB64" MYSQL_ROOT_PASSWORD="<pw>" MYSQL_PASSWORD="<pw>"   # or let Jenkins do it
```

- [ ] **Step 3: Redeploy and scale Ghost up on SQLite**

```bash
kubectl apply -f compiled.yaml
kubectl -n qcguy scale deployment/qcguy --replicas=1
kubectl -n qcguy rollout status deployment/qcguy --timeout=240s
curl -s -o /dev/null -w "%{http_code}\n" -H "X-Forwarded-Proto: https" https://www.qcguy.com/
```

Expected: `200`. Site is back on the original SQLite data. The CPU bug returns (expected) — diagnose MySQL separately and retry the migration later. MySQL StatefulSet can be left running or removed.

---

## Out of scope (optional fast-follow — do NOT do in this plan)

- A `mysqldump` backup CronJob for the new MySQL. Tracked as the recommended next step in the design doc; not part of this migration.
- Upstream Ghost source patch (MySQL sidesteps the bug).

---

## Self-review notes

- **Spec coverage:** MySQL StatefulSet (Task 2), Vault-injected secrets in `kv/qcguy/ghost` (Tasks 1/2/6), backup (Task 3), quiesce (Task 4), `sqlite3-to-mysql` conversion + row-count verification (Task 5), cutover + image pin to 6.47.0 (Task 6), post-cutover verification incl. CPU/`getTime`/content (Task 7), rollback to untouched SQLite (Task 8), backup CronJob noted out-of-scope. All design sections map to a task.
- **Open item resolved vs spec:** the spec flagged uncertainty about a second Vault path; this plan instead adds `MYSQL_*` keys to the existing `kv/qcguy/ghost` bundle, so the current single `vaultSync(app:'qcguy')` is unchanged.
- **No placeholders** except the intentional `<pw>` / `PUT_THE_MYSQL_PW...` markers, which reference the password generated in Task 1 Step 1 (a real value the operator holds).
