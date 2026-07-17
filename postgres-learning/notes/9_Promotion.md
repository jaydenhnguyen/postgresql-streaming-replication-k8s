# Promotion: `Standby` → `primary`

**Promotion** turns a read-only `standby` into a read-write `primary`. It is the core of failover: when the old `primary` 
dies (or is taken offline), the `standby` takes over and starts accepting writes.

This note covers what promotion actually does, the two ways to trigger it, why it is one-way, why rows can be lost, 
and - most importantly - **how to prevent data loss** before and during promotion.

Builds on [8_Standby_Initialization.md](./8_Standby_Initialization.md) (recovery mode, `standby.signal`) and 
[4_LSN.md](./4_LSN.md) (LSN gap, row-loss accounting).

---

## What Promotion Does

```
Before promotion                          After promotion
─────────────────                         ────────────────
standby.signal exists                     standby.signal DELETED
pg_is_in_recovery() = t                   pg_is_in_recovery() = f
Replays WAL (read-only)                   Generates WAL (read-write)
Follows primary via primary_conninfo      Becomes the new primary
Timeline T                                New timeline T+1
```

Step by step:

1. Finish replaying any WAL **already received** locally (received but not yet applied)
2. Delete `standby.signal` → exit recovery mode
3. Disconnect from the old `primary` (stop WAL Receiver)
4. Start a **new timeline** (timeline ID increments in WAL segment names)
5. Begin **generating** WAL for new writes
6. Accept INSERT/UPDATE/DELETE

```sql
-- Proof it worked
SELECT pg_is_in_recovery();   -- must be f
INSERT INTO events (tag) VALUES ('post-promo');  -- must succeed
```

👉 Promotion = "stop following, become the leader." It is **one-way** - going back requires re-seeding with 
`pg_basebackup`.

---

## Two Ways to Promote

Both must work for this project. Demo one; be ready to explain the other.

### Method 1: `pg_ctl promote`

```bash
# Inside the standby pod / on the standby host
pg_ctl promote -D /var/lib/postgresql/data/pgdata
```

Or via `kubectl`:

```bash
kubectl exec -n pg-<id> pg-standby-<id>-0 -- \
  pg_ctl promote -D /var/lib/postgresql/data/pgdata
```

### Method 2: Trigger file / `pg_promote()`

**Trigger file** - configure a path, then create that file to promote:

```
# postgresql.conf on the standby
promote_trigger_file = '/tmp/promote_standby'
```

```bash
# Create the file → PostgreSQL promotes
touch /tmp/promote_standby
```

**SQL function** (PostgreSQL 12+):

```sql
-- Run ON the standby
SELECT pg_promote();
-- returns t when promotion is triggered
```

| Method                 | How                                          | When to use                     |
|------------------------|----------------------------------------------|---------------------------------|
| `pg_ctl promote`       | CLI against the data directory               | Classic ops / shell runbook     |
| `promote_trigger_file` | Create a file on disk                        | Scripts, older automation       |
| `pg_promote()`         | SQL from a client connected to the `standby` | In-band, no shell access needed |

All three end the same way: `standby.signal` gone, `pg_is_in_recovery() = f`.

---

## Why Data Can Be Lost (Async Replication)

With **asynchronous** replication (this project's default):

```
Client ──► Primary: COMMIT OK     ← WAL only on primary disk
           Primary ──► Standby    ← may still be in flight or not yet received
```

If you promote while the `standby` is behind:

```
Primary WAL:  ──[row1]──[row2]──[row3]──[row4]──[row5]──
                                    ▲
                     standby replay_lsn at promotion

Survived:  rows 1, 2, 3
Lost:      rows 4, 5   (committed on old primary, never on the new timeline)
```

Full accounting walkthrough: [4_LSN.md - LSN at Promotion Time](./4_LSN.md).

👉 **Promotion does not invent missing WAL.** Whatever the `standby` never received is gone from the new `primary`.

---

## ‼️ How to Prevent Data Loss During Promotion

The root cause of failover row loss: **async replication acknowledges COMMIT before the `standby` has the data.** Every
solution is about **when** the commit is allowed to return - or about containing the damage afterward.

### Strategy 1 - Synchronous replication (zero loss of acknowledged commits)

Make the `primary` **wait for the `standby`** before returning COMMIT:

```
# postgresql.conf on primary
synchronous_standby_names = 'standby1'   # or application_name of the standby
synchronous_commit = on                  # wait until standby has flushed WAL
```

```
Client ──► Primary: write WAL
           Primary ──► Standby: send WAL, wait for confirmation
           Standby ──► Primary: "I have it (flushed)"
Client ◄── Primary: COMMIT OK   ← only now
```

|                           | Async              | Sync                                              |
|---------------------------|--------------------|---------------------------------------------------|
| Rows lost on failover     | Some (the lag gap) | **Zero** - every acked commit is on the `standby` |
| Commit latency            | Low                | Higher (waits for network round-trip)             |
| If `standby` is down/slow | Nothing happens    | **`primary` BLOCKS on commit** - writes hang      |

‼️ **The tradeoff:** sync trades **availability** for **durability**. With `synchronous_commit = on`, an insert loop
would **stall** (hang waiting) instead of losing rows when the `standby` lags or dies.

Levels of wait:

| `synchronous_commit` | `primary` waits until...                                                                               |
|----------------------|--------------------------------------------------------------------------------------------------------|
| `off`                | Does not even wait for local WAL flush before replying                                                 |
| `local`              | WAL durable on `primary` only; does not wait for `standby`.                                            |
| `remote_write`       | `standby` received and wrote WAL to its operating-system buffers, but may not have flushed it to disk. |
| `on`                 | `standby` flushed WAL to durable storage. Recommended for normal synchronous replication.              |
| `remote_apply`       | `standby` flushed and replayed WAL, so the transaction is already visible to queries there.            |

👉 `remote_apply` is strongest but slowest.

👉 Sync is the only way to guarantee **"if the client got COMMIT, the `standby` has it."** The cost is availability: 
writes hang when the `standby` cannot confirm.

### Strategy 2 - Promote only when lag is near zero (operational)

Before promoting, **wait until the `standby` has caught up**:

```sql
-- On primary: watch the gap shrink
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;

-- On standby
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
```

```
1. Stop (or pause) new writes to the old primary if possible
2. Wait until lag_bytes ≈ 0
3. THEN promote
```

👉 This works well for **planned** failovers (maintenance). For **unplanned** failovers (`primary` already dead), we cannot 
wait - the missing WAL may never arrive. Then we accept the loss and account for it with LSN + row counts.

👉 Planned failover: drain lag to zero, then promote. Unplanned: promote immediately, then reconcile exact losses.

### Strategy 3 - Quorum of multiple `standbys`

```
synchronous_standby_names = 'ANY 1 (standby1, standby2)'
```

COMMIT returns when **at least one** `standby` confirms. Survives one `standby` dying without blocking forever. The 
surviving confirmed `standby` can be promoted with zero acknowledged-commit loss.

👉 Softens Solution 1's availability problem while keeping most of its durability.

### Strategy 4 - Replication slots (do not lose the *stream* - prevents a DIFFERENT loss)

A **replication slot** does not stop failover row loss - it prevents the `primary` from **recycling WAL the `standby`
still needs**:

```sql
SELECT pg_create_physical_replication_slot('standby1_slot');
-- standby: primary_slot_name = 'standby1_slot'
```

```
Without slot: primary recycles WAL → standby cannot catch up → broken → re-basebackup
With slot:    primary keeps WAL   → standby always able to catch up
```

Also set a safety cap so a dead `standby` cannot fill the `primary` disk:

```
max_slot_wal_keep_size = 10GB
```

‼️ Watch disk usage: a dead `standby` + a slot = WAL piles up forever on the `primary`.

See [6_Replication_Slots.md](./6_Replication_Slots.md).

### Strategy 5 - Fence the old `primary` (prevent post-promotion loss / split-brain)

After promotion, the "lost" rows may still be alive on the old `primary`. If clients keep writing there, two
timelines diverge:

```
After promoting standby:
  Old primary still up  →  clients might write to it  →  split-brain
```

| Action                                         | Effect                                           |
|------------------------------------------------|--------------------------------------------------|
| Repoint the write Service to the new `primary` | Clients only reach the promoted node             |
| Stop / delete the old `primary` pod            | It cannot accept writes                          |
| STONITH ("shoot the other node in the head")   | HA tools kill the old `primary` before promoting |


In Kubernetes, patching the write Service selector is the practical step:

```bash
# Example: repoint clients after promote
kubectl patch svc pg-write -n pg-<id> \
  -p '{"spec":{"selector":{"app":"pg-standby-<id>"}}}'
```

👉 Fencing does not recover pre-promotion lag loss - it prevents **new** divergence after promotion.

### Strategy 6 - Automated HA (production)

Manual failover is error-prone. Real systems use orchestrators that combine sync replication + health checks +
automatic promotion + fencing:

| Tool              | What it does                                        |
|-------------------|-----------------------------------------------------|
| **Patroni**       | Leader election, auto-promote, fences old `primary` |
| **repmgr**        | Failover automation + monitoring                    |
| **CloudNativePG** | Kubernetes operator: promotion + service cutover    |
---

## Decision Guide: Preventing Loss

```
Need zero loss of acked commits?     → synchronous replication (1)
Planned maintenance failover?        → stop writes + wait lag ≈ 0 (2), then promote
Tolerate one standby failure?        → quorum sync (3)
Keep standby able to catch up?       → replication slot (4)
Avoid split-brain after promote?     → fence old primary + repoint Service (5)
Production automation?               → Patroni / CloudNativePG (6)
```

👉 For **this project** (async by design, so you can *demonstrate* loss):
1. Show the LSN gap under write load
2. Promote mid-burst
3. State exact counts: made it / lost / why (replay LSN cut line)
4. Explain: `synchronous_commit = on` would have made loss **zero**, but the insert loop would **block** if the 
   `standby` lagged or died
5. Repoint `pg-write` and prove the new `primary` accepts writes

---

## Full Promotion Runbook (Project Shape)

```
# 0. Capture lag BEFORE promote (for the accounting story)
#    primary:  pg_current_wal_lsn() + pg_stat_replication.replay_lsn
#    standby:  pg_last_wal_replay_lsn()

# 1. Promote
kubectl exec -n pg-<id> pg-standby-<id>-0 -- \
  pg_ctl promote -D /var/lib/postgresql/data/pgdata

# 2. Confirm role flip
kubectl exec -n pg-<id> pg-standby-<id>-0 -- \
  psql -U postgres -c "SELECT pg_is_in_recovery();"
# → f

# 3. Fence / repoint clients
kubectl patch svc pg-write ...   # selector → new primary labels

# 4. Prove writes work
# INSERT ... tag = '<id>-post-promo'

# 5. Reconcile rows
# SELECT count(*), max(id) FROM events_<id>;
# Compare vs writer-reported sends → exact made-it / lost
```

---

## Summary

👉 Promotion deletes `standby.signal`, exits recovery, starts a new timeline, and begins accepting writes - 
**one-way**.

👉 Two methods: `pg_ctl promote` and trigger-file / `pg_promote()` - same end state.

👉 Async promotion can lose rows that committed on the old `primary` but never reached the `standby` - the LSN gap is 
the cut line ([4_LSN.md](./4_LSN.md)).

👉 **Prevent loss:** sync replication (zero acked-commit loss), wait for lag ≈ 0 on planned failovers, quorum
`standbys`, slots (keep the stream intact), fence the old `primary` (no split-brain).

👉 Sync trades **durability** for **availability**: no lost acked commits, but COMMIT blocks when the `standby` cannot 
confirm.

---

## References

- [8_Standby_Initialization.md](./8_Standby_Initialization.md) - recovery mode, `standby.signal`, `pg_is_in_recovery()`
- [4_LSN.md](./4_LSN.md) - row-loss accounting, sync vs async solutions
- [6_Replication_Slots.md](./6_Replication_Slots.md) - keeping WAL for the `standby`
- [PostgreSQL Documentation - Failover](https://www.postgresql.org/docs/current/warm-standby-failover.html)
- [PostgreSQL Documentation - pg_promote](https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-RECOVERY-CONTROL)
