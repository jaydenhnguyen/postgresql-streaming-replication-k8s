# Runbook

Operational guide for this project's local PostgreSQL primary + hot standby on [kind](https://kind.sigs.k8s.io/).

## Goal

Bring up a two-node streaming replication cluster from scratch, prove it is healthy, measure lag under write load, practice failover (promote + client cutover), and tear it down cleanly so you can rebuild anytime.

## What you practice if you follow start to finish

- Bootstrapping stateful Postgres on Kubernetes (StatefulSets, headless Services, Secrets, PVCs)
- How physical streaming replication looks in practice (`pg_stat_replication`, LSNs, byte lag)
- Why a hot standby is read-only until promotion
- Failover: `pg_ctl promote` / `pg_promote()`, then repointing a write Service
- Accounting for rows that async replication can lose across a promote window
- Idempotent destroy + rebuild of a local kind environment

Copy-paste the commands below. Work from the `solution/` directory.

Optional shell shortcuts (typing only - not part of the cluster):

```shell
export ENV_ID=hdhnguyen
export NS=pg-${ENV_ID}
export PRIMARY=pg-primary-${ENV_ID}-0
export STANDBY=pg-standby-${ENV_ID}-0
export PGDATA=/var/lib/postgresql/18/docker
```

`ENV_ID` is the same id you pass to `./bootstrap.sh`. Change `hdhnguyen` if you use another id, or skip the exports and type full names.

---

## 1. Bootstrap from nothing

```shell
cd solution
cp scripts/.env.example scripts/.env
./bootstrap.sh ${ENV_ID}
```

Healthy afterward:

```shell
kubectl get pods,pvc -n ${NS} -o wide
```
---

## 2. Check replication lag

On a quiet kind cluster, catch-up is often too fast to see. Pause WAL **replay** on the standby, write on the primary, 
then resume - so `lag_bytes` grows, and we can show real LSN numbers.

Use **two terminals**. Both need the exports from the top of this file.

| Value                                     | Meaning                                               |
|-------------------------------------------|-------------------------------------------------------|
| `pg_current_wal_lsn()`                    | latest WAL on primary                                 |
| `pg_last_wal_replay_lsn()` / `replay_lsn` | How far the standby has applied WAL                   |
| `lag_bytes`                               | Byte gap (`primary - replay`) via `pg_wal_lsn_diff()` |

---

### Step 2.1 - Confirm streaming (Terminal A)

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

### Step 2.2 - get the latest WAL on primary (Terminal A)

```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_current_wal_lsn() AS primary_lsn;"
```

**Expected output:** One LSN like `0/3A4B2C8` (exact hex differs each run).

---

### Step 2.3 - get the latest replayed WAL on Standby (Terminal A)

Reads how far the standby has applied WAL. Same idea as `replay_lsn` in `pg_stat_replication` on the primary

```bash
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_last_wal_replay_lsn() AS replay_lsn;"
```

**Expected output:** An LSN close to Step 2.2

---

### Step 2.4 - get the Lag in bytes (Terminal A)

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

### Step 2.5 - Pause WAL replay on the standby (Terminal A)

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

### Step 2.6 - Start the write (Terminal B)
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

### Step 2.7 - Primary LSN (Terminal A)

```bash
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_current_wal_lsn() AS primary_lsn;"
```

**Expected output:** The WAL tip on Primary keeps **changing** due to the continuous writing.

---

### Step 2.8 - Received vs. Replayed on the Standby (Terminal A)

The Standby keeps receiving the WAL from the Primary but not replay those WAL

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

### Step 2.9 - lag_bytes from the Primary (Terminal A)

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

### Step 2.10 - Resume WAL replay (Terminal A)
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

### Step 2.11 - lag_bytes after catch-up (Terminal A)

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

## 3. Generate write load on the primary

Used during the lag demo (section 2, Step 2.7). Run in its own terminal:

```bash
while true; do
  kubectl exec -n ${NS} ${PRIMARY} -- \
    psql -h localhost -U postgres -d clo835 -c \
    "INSERT INTO events_${ENV_ID} (tag)
     VALUES ('load-${ENV_ID}-' || clock_timestamp());"
  sleep 0.2
done
```

Stop with `Ctrl-C`. For a visible LSN gap on kind, pause replay first (section 2, Steps 2.5-2.6), then start this loop.

---

## 4. Verify the standby is read-only

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

## 5. Promote the standby

### Method A - `pg_ctl promote`

```shell
kubectl exec -n ${NS} ${STANDBY} -- \
  pg_ctl promote -D ${PGDATA}
```

Confirm:

```shell
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_is_in_recovery();"
```

Must return `f`.

### Method B - `pg_promote()` / trigger-file alternative

```shell
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_promote();"
```

Confirm again with `SELECT pg_is_in_recovery();` - expect `f`.

`pg_ctl promote` and `pg_promote()` both end recovery. The trigger-file path is the same mechanism PostgreSQL uses internally.

---

## 6. Repoint clients (`pg-write`)

Before (selector points at primary):

```shell
kubectl get svc pg-write -n ${NS} -o jsonpath='{.spec.selector}{"\n"}'
```

Patch to the promoted standby labels:

```shell
kubectl patch svc pg-write -n ${NS} --type=merge -p \
  "{\"spec\":{\"selector\":{\"app\":\"postgres\",\"role\":\"standby\",\"student-id\":\"${ENV_ID}\"}}}"
```

Prove writes land on the new primary:

```shell
kubectl run -n ${NS} psql-write-test --rm -it --restart=Never \
  --image=postgres:18 -- \
  psql -h pg-write -U postgres -d clo835 -c \
  "INSERT INTO events_${ENV_ID} (tag) VALUES ('via-pg-write');
   SELECT id, tag FROM events_${ENV_ID} ORDER BY id DESC LIMIT 3;"
```

Fence the old primary to avoid split-brain:

```shell
kubectl scale statefulset pg-primary-${ENV_ID} -n ${NS} --replicas=0
```

---

## 7. Count and reconcile rows after promotion

On the promoted node (former standby):

```shell
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT count(*), max(id) FROM events_${ENV_ID};"
```

On the old primary (if it still exists):

```shell
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -d clo835 -c \
  "SELECT count(*), max(id) FROM events_${ENV_ID};"
```

With async replication, commits on the old primary whose WAL position was **after** the standby `replay_lsn` at promote time do not appear on the new timeline. Compare counts (or your write-loop total vs promoted `count(*)`) and note exactly how many rows made it and how many did not, using the LSN / `lag_bytes` from section 2.

---

## 8. Tear down and rebuild

```shell
cd solution
./destroy.sh ${ENV_ID}
./bootstrap.sh ${ENV_ID}
```

Equivalent cluster delete:

```shell
kind delete cluster --name pg-replication
```

Then re-run bootstrap and confirm health with section 1.
