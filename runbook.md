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

`ENV_ID` is the same id you pass to `./scripts/bootstrap.sh`. Change `hdhnguyen` if you use another id, or skip the exports and type full names.

---

## 1. Bootstrap from nothing

```shell
cd solution
cp scripts/.env.example scripts/.env   # optional; edit passwords or skip for random
./scripts/bootstrap.sh ${ENV_ID}
```

Healthy afterward:

```shell
kubectl get pods,pvc -n ${NS} -o wide
```

Expect both pods `1/1 Running` on different workers, two PVCs `Bound`.

```shell
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT state, sync_state, replay_lsn FROM pg_stat_replication;"
```

Expect one row with `state = streaming`.

---

## 2. Check replication lag

Primary:

```shell
kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_current_wal_lsn();"

kubectl exec -n ${NS} ${PRIMARY} -- \
  psql -h localhost -U postgres -c \
  "SELECT state, sync_state, replay_lsn,
          pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
   FROM pg_stat_replication;"
```

Standby:

```shell
kubectl exec -n ${NS} ${STANDBY} -- \
  psql -h localhost -U postgres -c \
  "SELECT pg_last_wal_replay_lsn();"
```

| Value                                     | Meaning                                               |
|-------------------------------------------|-------------------------------------------------------|
| `pg_current_wal_lsn()`                    | WAL tip on the primary                                |
| `pg_last_wal_replay_lsn()` / `replay_lsn` | How far the standby has applied WAL                   |
| `lag_bytes`                               | Byte gap (`primary - replay`) via `pg_wal_lsn_diff()` |

Under write load, `lag_bytes` should rise, then fall as the standby catches up.

---

## 3. Generate write load on the primary

```shell
while true; do
  kubectl exec -n ${NS} ${PRIMARY} -- \
    psql -h localhost -U postgres -d clo835 -c \
    "INSERT INTO events_${ENV_ID} (tag)
     VALUES ('load-${ENV_ID}-' || clock_timestamp());"
  sleep 0.2
done
```

Stop with Ctrl-C. Re-run the lag checks in section 2 while this runs.

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
./scripts/destroy.sh ${ENV_ID}
./scripts/bootstrap.sh ${ENV_ID}
```

Equivalent cluster delete:

```shell
kind delete cluster --name pg-replication
```

Then re-run bootstrap and confirm health with section 1.
