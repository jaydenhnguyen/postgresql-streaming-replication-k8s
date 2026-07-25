# Runbook

Operational guide for this project's local PostgreSQL primary + hot standby on [kind](https://kind.sigs.k8s.io/).

## Goal

Bring up a two-node streaming replication cluster from scratch, prove seed data on both roles, confirm the standby is 
read-only, measure lag under a writing load, practice failover (promote + client cutover), and tear it down cleanly so 
you can rebuild anytime.

## What you practice if you follow start to finish

- Bootstrapping stateful Postgres on Kubernetes (StatefulSets, headless Services, Secrets, PVCs)
- How physical streaming replication looks in practice (`pg_stat_replication`, LSNs, byte lag)
- Why a hot standby is read-only until promotion
- Failover: `pg_ctl promote` / `pg_promote()`, then repointing a writing Service
- Accounting for rows that async replication can lose across a promoted window
- Idempotent destroy + rebuild of a local kind environment

Copy-paste the commands below. Work from the `src/` directory.

Optional shell shortcuts (typing only - not part of the cluster):

```shell
export ENV_ID=hdhnguyen
export NS=pg-${ENV_ID}
export PRIMARY=pg-primary-${ENV_ID}-0
export STANDBY=pg-standby-${ENV_ID}-0
export PGDATA=/var/lib/postgresql/18/docker
```

`ENV_ID` is the same id you pass to `./bootstrap.sh`. Change `hdhnguyen` if you use another id, or skip the exports and 
type full names.

---

## 1. Bootstrap from nothing

```shell
cd src
cp .env.example .env
./bootstrap.sh ${ENV_ID}
```

Healthy afterward — pods/PVCs up, and one streaming standby:

```shell
kubectl get pods,pvc -n ${NS} -o wide

kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT state, sync_state, replay_lsn FROM pg_stat_replication;"
```

**Expected output:** both Postgres pods `Running` (on different workers), PVCs `Bound`, and:

```text
   state   | sync_state | replay_lsn
-----------+------------+------------
 streaming | async      | 0/........
(1 row)
```

---

## 2. Verify seed data on primary and standby

Bootstrap already creates database `clo835`, table `events_${ENV_ID}`, and seed rows. Confirm on the primary:

```shell
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT * FROM events_${ENV_ID} LIMIT 5;"
```

The same query on the standby - rows should match:

```shell
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT * FROM events_${ENV_ID} LIMIT 5;"
```

INSERT on the primary, then re-check the standby:

```shell
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "INSERT INTO events_${ENV_ID} (tag) VALUES ('demo-${ENV_ID}');
   SELECT id, tag FROM events_${ENV_ID} ORDER BY id DESC LIMIT 3;"

kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT id, tag FROM events_${ENV_ID} ORDER BY id DESC LIMIT 3;"
```

---

## 3. Verify the standby is read-only

```shell
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "INSERT INTO events_${ENV_ID} (tag) VALUES ('should-fail');"
```

Expect: `ERROR: cannot execute INSERT in a read-only transaction`

```shell
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_is_in_recovery();"
```

Expect: `t`

---

## 4. Check replication lag

On a quiet kind cluster, catch-up is often too fast to see. Pause WAL **replay** on the standby, write on the primary, 
then resume - so `lag_bytes` grows, and we can show real LSN numbers.

Use **two terminals**. Both need the exports from the top of this file.

| Value                                     | Meaning                                               |
|-------------------------------------------|-------------------------------------------------------|
| `pg_current_wal_lsn()`                    | latest WAL on primary                                 |
| `pg_last_wal_replay_lsn()` / `replay_lsn` | How far the standby has applied WAL                   |
| `lag_bytes`                               | Byte gap (`primary - replay`) via `pg_wal_lsn_diff()` |

---

### Step 1 - Confirm streaming (Terminal A)

```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT state, sync_state, replay_lsn FROM pg_stat_replication;"
```

**Expected output:**
```text
   state   | sync_state | replay_lsn
-----------+------------+------------
 streaming | async      | 0/........
(1 row)
```

---

### Step 2 - get the latest WAL on primary (Terminal A)

```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_current_wal_lsn() AS primary_lsn;"
```

**Expected output:** One LSN like `0/3A4B2C8` (exact hex differs each run).

---

### Step 3 - get the latest replayed WAL on Standby (Terminal A)

Reads how far the standby has applied WAL. Same idea as `replay_lsn` in `pg_stat_replication` on the primary

```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_last_wal_replay_lsn() AS replay_lsn;"
```

**Expected output:** An LSN close to Step 2

---

### Step 4 - get the Lag in bytes (Terminal A)

Computes the byte gap between primary tip and standby replay.

**Command:**
```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_current_wal_lsn() AS primary_lsn,
          replay_lsn AS standby_replay_lsn,
          pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
   FROM pg_stat_replication;"
```

**Expected output:**
```text
 primary_lsn | standby_replay_lsn | lag_bytes
-------------+--------------------+-----------
 0/........  | 0/........         |         0
```
`lag_bytes` is often `0` or a small number when idle. Small nonzero idle lag is normal for async.

---

### Step 5 - Pause WAL replay on the standby (Terminal A)

Freezes apply on the standby. WAL can still be **received**; it will not be **replayed** until you resume. 
This makes the lag easy to demonstrate.

```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_wal_replay_pause();"
```

Confirm replay is paused:
```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_is_wal_replay_paused();"
```
**Expected output:**
```text
 pg_is_wal_replay_paused
-------------------------
 t
```

---

### Step 6 - Start the writing (Terminal B)
Generates WAL on the primary while replay on Standby is paused.

Open a **second** terminal, run the same exports, then:
```bash
while true; do
  kubectl exec -n ${NS} ${PRIMARY} -- \
    psql -h localhost -U postgres -d clo835 -c \
    "INSERT INTO events_${ENV_ID} (tag)
     VALUES ('load-${ENV_ID}-' || clock_timestamp());"
  sleep 0.2
done
```

**Expected output:** Repeating `INSERT 0 1`. Leave it running.

---

### Step 7 - Primary LSN (Terminal A)

```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_current_wal_lsn() AS primary_lsn;"
```

**Expected output:** The WAL tip on Primary keeps **changing** due to the continuous writing.

---

### Step 8 - Received vs. Replayed on the Standby (Terminal A)

The Standby keeps receiving the WAL from the Primary but not replaying those WAL

```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_last_wal_receive_lsn() AS receive_lsn,
          pg_last_wal_replay_lsn()  AS replay_lsn,
          pg_wal_lsn_diff(
            pg_last_wal_receive_lsn(),
            pg_last_wal_replay_lsn()
          ) AS receive_minus_replay_bytes;"
```

**Expected output:** the `pg_last_wal_receive_lsn()` on Standby must be same as the `pg_current_wal_lsn()` on Primary. 
But the `replay_lsn` is behind the `pg_last_wal_receive_lsn()`

---

### Step 9 - lag_bytes from the Primary (Terminal A)

Shows the byte lag from the Primary tip to Standby replay.

```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_current_wal_lsn() AS primary_lsn,
          replay_lsn AS standby_replay_lsn,
          pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
   FROM pg_stat_replication;"
```

**Expected output:** `lag_bytes` clearly **larger than idle** (often growing while the loop runs). `state` can still 
be `streaming`.

---

### Step 10 - Resume WAL replay (Terminal A)
```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_wal_replay_resume();"
```

Confirm replay is no longer paused:
```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_is_wal_replay_paused();"
```
**Expected output:**
```text
 pg_is_wal_replay_paused
-------------------------
 f
```

### Step 11 - lag_bytes after catch-up (Terminal A)

The gap closed after the resume.

Wait 2-5 seconds, then:

```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_current_wal_lsn() AS primary_lsn,
          replay_lsn AS standby_replay_lsn,
          pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
   FROM pg_stat_replication;"
```

**Expected output:** `lag_bytes` back near idle (`0` or small). Primary and replay LSNs close again.

---

## 5. Promote, repoint, fence, and reconcile

Promote ends recovery on the standby (Postgres becomes writable).

Kubernetes labels do **not** change - the pod still has `role: standby`.

Repoint `pg-write` so clients follow the new writer, then scale the old primary to `0` so only one node accepts writes
(avoid two primaries / split-brain).

Finally, count exact `sent` / `made_it` / `lost`.

In this section you **pause replay**, insert tagged `pre-promo-*` rows, then promote. Promote ends the pause and
**replays already-received WAL before** the node becomes read-write - so those rows appear on the new primary even
though they were invisible on the standby while paused.

| Value     | Meaning                                                                                                                  |
|-----------|--------------------------------------------------------------------------------------------------------------------------|
| `sent`    | Rows you inserted on the old primary before promote (`pre-promo-1` … `pre-promo-30`)                                     |
| `made_it` | How many of those rows exist on the promoted node                                                                        |
| `lost`    | `sent - made_it` - commits the standby had **not received** yet when promote ran (still in flight / only on old primary) |

---

### Step 1 - Confirm streaming (Terminal A)

```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT state, sync_state, replay_lsn FROM pg_stat_replication;"
```

**Expected output:**
```text
   state   | sync_state | replay_lsn
-----------+------------+------------
 streaming | async      | 0/........
(1 row)
```

---

### Step 2 - Snapshot row counts on both pods (Terminal A)

```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT count(*) AS n, max(id) AS max_id FROM events_${ENV_ID};"

kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT count(*) AS n, max(id) AS max_id FROM events_${ENV_ID};"
```

**Expected output:** Same `n` and `max_id` on both (or standby a tiny bit behind if something just wrote).

---

### Step 3 - Snapshot LSN / lag_bytes (Terminal A)

```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_current_wal_lsn() AS primary_lsn,
          replay_lsn AS standby_replay_lsn,
          pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
   FROM pg_stat_replication;"
```

**Expected output:** One row. `lag_bytes` is often `0` or small when idle.

---

### Step 4 - Pause replay, then write countable rows on the primary

Pause freezes **apply** on the standby. WAL can still be **received**, but those commits do not show up in
`SELECT` until replay runs (or until promoting, which ends the pause and applies received WAL first).

```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_wal_replay_pause();"
```

Confirm replay is paused:

```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_is_wal_replay_paused();"
```

**Expected output:**
```text
 pg_is_wal_replay_paused
-------------------------
 t
```

Then open a **second** terminal, run the same exports, and insert tagged rows on the primary (`pre-promo-*` =
rows written before promote):

```bash
for i in $(seq 1 30); do
  kubectl exec -n ${NS} ${PRIMARY} -- \
    psql -h localhost -U postgres -d clo835 -c \
    "INSERT INTO events_${ENV_ID} (tag) VALUES ('pre-promo-${i}');" >/dev/null
  echo "sent pre-promo-${i}"
  sleep 0.1
done
echo "SENT=30"
```

**Expected output:** Lines `sent pre-promo-1` … `sent pre-promo-30`, then `SENT=30`.

Do **not** call `pg_wal_replay_resume()` - continue to Step 5 and promote. Promote will apply the received WAL.

---

### Step 5 - Re-snapshot right before promoting (Terminal A)

While replay is still paused, the standby table should be missing the `pre-promo-*` rows (they are in received WAL,
not applied yet).

```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT count(*) AS primary_n,
          count(*) FILTER (WHERE tag LIKE 'pre-promo-%') AS primary_pre_promo_count
   FROM events_${ENV_ID};"

kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT count(*) AS standby_n,
          count(*) FILTER (WHERE tag LIKE 'pre-promo-%') AS standby_pre_promo_count,
          pg_last_wal_replay_lsn() AS replay_lsn,
          pg_last_wal_receive_lsn() AS receive_lsn
   FROM events_${ENV_ID};"
```

**Expected output:**
- `primary_pre_promo_count` = `30`
- `standby_pre_promo_count` = `0` (or far behind) while paused
- `receive_lsn` ahead of `replay_lsn` (WAL received, not yet applied)

---

### Step 6 - Promote the standby (Terminal A)

Method A (`pg_ctl promote`):

```bash
kubectl exec -n ${NS} ${STANDBY} -- gosu postgres pg_ctl promote -D ${PGDATA}
```

**Expected output:**
```text
waiting for server to promote.... done
server promoted
```

Method B (alternative - try once on a rebuild):

```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_promote();"
```

**Expected output:** `t` (promote requested). Pod name and K8s labels stay `role: standby`.

Promote ends the replay pause and applies already-received WAL **before** the node becomes read-write.

---

### Step 7 - Confirm not in recovery (Terminal A)

```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_is_in_recovery();"
```

**Expected output:**
```text
 pg_is_in_recovery
-------------------
 f
```

---

### Step 8 - Confirm paused WAL was applied on the new primary (Terminal A)

The `pre-promo-*` rows that were invisible on the standby in Step 5 should now all be present on the promoted node.

```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT count(*) FILTER (WHERE tag LIKE 'pre-promo-%') AS standby_pre_promo_count
   FROM events_${ENV_ID};"

kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT id, tag FROM events_${ENV_ID}
   WHERE tag LIKE 'pre-promo-%'
   ORDER BY id;"
```

**Expected output:**
- `standby_pre_promo_count` = `30` (same as `SENT`)
- All tags `pre-promo-1` … `pre-promo-30` listed

That is the pause story: received-but-unreplayed WAL is replayed as part of promoting, so the new primary has that data.

---

### Step 9 - Prove writes on the promoted pod (Terminal A)

```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "INSERT INTO events_${ENV_ID} (tag) VALUES ('${ENV_ID}-post-promo');
   SELECT id, tag FROM events_${ENV_ID} ORDER BY id DESC LIMIT 3;"
```

**Expected output:** INSERT succeeds. The latest tag is `${ENV_ID}-post-promo`.

The old primary is still writable until you fence it (Step 14).

---

### Step 10 - Check `pg-write` selector before repoint (Terminal A)

```bash
kubectl get svc pg-write -n ${NS} -o jsonpath='{.spec.selector}{"\n"}'
```

**Expected output:** selector still has `"role":"primary"` (points at the old writer).

---

### Step 11 - Repoint `pg-write` to the promoted pod (Terminal A)

Same DNS name; new backend labels (`role: standby`).

```bash
kubectl patch svc pg-write -n ${NS} --type=merge -p \
  "{\"spec\":{\"selector\":{\"app\":\"postgres\",\"role\":\"standby\",\"student-id\":\"${ENV_ID}\"}}}"
```

**Expected output:** `service/pg-write patched`

Confirm:

```bash
kubectl get svc pg-write -n ${NS} -o jsonpath='{.spec.selector}{"\n"}'
```

**Expected output:** `"role":"standby"` with the same `student-id`.

---

### Step 12 - Write through `pg-write` (Terminal A)

```bash
kubectl run -n ${NS} psql-write-test --rm --restart=Never \
  --image=postgres:18 -- \
  psql -h pg-write -U postgres -d clo835 -c \
  "INSERT INTO events_${ENV_ID} (tag) VALUES ('via-pg-write');
   SELECT id, tag FROM events_${ENV_ID} ORDER BY id DESC LIMIT 3;"
```

**Expected output:** INSERT succeeds; latest rows include `via-pg-write` (and `${ENV_ID}-post-promo`).

If `psql` asks for a password, use `POSTGRES_PASSWORD` from `src/.env`.

---

### Step 13 - Reconcile rows (Terminal A)

On the new primary (promoted standby):

```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT count(*), max(id) FROM events_${ENV_ID};"
```

On the old primary (still running until Step 14):

```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT count(*), max(id) FROM events_${ENV_ID};"
```

**Expected output:** Two numbers per side (`count`, `max(id)`). If the old primary was ahead at promote time, its `count` / `max(id)` can be higher than the promoted node.

Optional — tagged `pre-promo-*` check from this section's practice path:

```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT count(*) FILTER (WHERE tag LIKE 'pre-promo-%') AS standby_pre_promo_count
   FROM events_${ENV_ID};"
```

Then calculate (practice path):

- `sent` = `30` (from Step 4)
- `made_it` = `standby_pre_promo_count`
- `lost` = `sent - made_it` → usually `0` here, because promote applied the received WAL

`lost > 0` when commits were still **only on the old primary** (not yet received by the standby) at promote
time - compare the two `count(*)` / `max(id)` results above, or count the instructor's tag on each side.

---

### Step 14 - Fence the old primary (Terminal A)

Stops the old primary from accepting writes (avoids two primaries / split-brain). Do this **after** reconcile so both pods are still queryable in Step 13.

```bash
kubectl scale statefulset pg-primary-${ENV_ID} -n ${NS} --replicas=0
```

**Expected output:** `statefulset.apps/pg-primary-${ENV_ID} scaled`

```bash
kubectl get pods -n ${NS} -o wide
```

**Expected output:** Only the promoted standby pod is `Running`. Old primary is gone or `Terminating`.

---

## 6. Tear down and rebuild

Needed after section 5 before another full failover practice.

```shell
cd src
./destroy.sh ${ENV_ID}
./bootstrap.sh ${ENV_ID}
```

Equivalent cluster delete:

```shell
kind delete cluster --name pg-replication
```

Then re-run the bootstrap and confirm health with section 1.
