# PostgreSQL Streaming Replication on Kubernetes

A two-node PostgreSQL cluster on [kind](https://kind.sigs.k8s.io/) with physical streaming replication: a write primary, a hot standby seeded by `pg_basebackup`, measurable WAL lag, and scripted failover with client cutover.

Provisioned from raw Kubernetes manifests and a single bootstrap script. No Helm, no operators, no managed database services.

---

## Overview

Primary and standby run as separate StatefulSets with asymmetric roles. The primary ships WAL; the standby replays it and stays read-only until promoted. Bootstrap brings a clean host to a streaming, seeded cluster. The runbook covers lag checks, write load, promotion, service repointing, and post-failover row reconciliation.

---

## Architecture

![Architecture](./assets/architecture.png)

| Component | Role |
|-----------|------|
| **kind cluster** | 1 control-plane + 2 workers; primary and standby scheduled onto different workers |
| **Primary StatefulSet** | Accepts writes, generates WAL, exposes replication stats |
| **Standby StatefulSet** | Seeded by an idempotent `pg_basebackup` initContainer; read-only until promoted |
| **Headless Services** | Stable DNS for pod-to-pod replication |
| **`pg-write` Service** | Single ClusterIP endpoint for clients; selector updated after failover |
| **ConfigMap** | Replication settings (`wal_level`, `max_wal_senders`, `pg_hba`) |
| **Secret** | Database credentials generated at bootstrap — never stored in git |

Persistent volumes use the kind `local-path` StorageClass (one PVC per pod). Runtime image: official `postgres:16`.

---

## Highlights

- Physical streaming replication with `primary_conninfo` and replication slots
- StatefulSets, headless Services, and PVC-backed data directories
- Idempotent standby seed: `pg_basebackup -R -X stream` only when the data directory is empty
- Lag measured with `pg_current_wal_lsn()`, `pg_last_wal_replay_lsn()`, and `pg_wal_lsn_diff()`
- Failover via `pg_ctl promote` or `pg_promote()` / trigger file
- Client cutover by patching the `pg-write` Service to the new primary
- Clear accounting of async replication gaps using LSN and row counts
- Fully parameterized bootstrap and tear-down

---

## Tech stack

| Layer | Choice |
|-------|--------|
| Database | PostgreSQL 16 |
| Cluster | kind (local Kubernetes) |
| Storage | `local-path` StorageClass |
| Tooling | `kubectl`, `psql`, `watch` |
| Delivery | Raw YAML manifests + shell bootstrap |

---

## Quick start

**Prerequisites:** Docker, [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation), [kubectl](https://kubernetes.io/docs/tasks/tools/)

```bash
./bootstrap.sh <env-id>

kubectl get pods,pvc -n pg-<env-id> -o wide

kubectl exec -n pg-<env-id> pg-primary-<env-id>-0 -- \
  psql -U postgres -c "SELECT state, sync_state, replay_lsn FROM pg_stat_replication;"
```

Day-2 procedures (lag, load, promote, cutover, rebuild) are in [runbook.md](./runbook.md).

---

## Repository layout

```
.
├── kind-config.yaml      # kind: 1 control-plane + 2 workers
├── bootstrap.sh          # One-shot provisioning (parameterized by env id)
├── runbook.md            # Operational procedures
├── manifests/
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── secret.yaml       # template — secrets created at bootstrap
│   ├── primary-statefulset.yaml
│   ├── standby-statefulset.yaml
│   ├── services.yaml
│   └── seed-job.yaml
└── evidence/             # Sample bootstrap / lag / failover transcripts
```

Namespace, resource names, and seed data are all derived from the env id passed to `bootstrap.sh`.

---

## Operations

### Replication lag

```sql
-- Primary
SELECT pg_current_wal_lsn();
SELECT state, sync_state, replay_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;

-- Standby
SELECT pg_last_wal_replay_lsn();
```

### Failover

1. Promote the standby (`pg_ctl promote` or `pg_promote()`)
2. Confirm `pg_is_in_recovery()` returns `f`
3. Point `pg-write` at the new primary
4. Fence the old primary to avoid split-brain
5. Reconcile row counts against the write stream using the replay LSN at promote time

Details: [runbook.md](./runbook.md).

---

## Design decisions

**Separate StatefulSets for primary and standby.** Roles are not interchangeable. Promoting the standby should not require rewriting a shared replica set.

**InitContainer seeding.** Streaming replication only ships WAL. The standby needs a consistent base backup first; `-R` writes `standby.signal` and `primary_conninfo`. The initContainer is idempotent so a re-attached PVC is not re-copied on every restart.

**One write Service.** Clients talk to `pg-write`. After failover, a selector patch moves traffic without changing application config.

**Async replication by default.** Commits that have not reached the standby’s replay position at promote time do not appear on the new timeline. Lag and row counts make that visible and explainable.

**Credentials stay out of git.** Passwords are created in-cluster at bootstrap and held in a Kubernetes Secret.

---

## License

MIT
