# Synchronous Replication

**Goal:** Understand what makes a standby *synchronous*, why `application_name` matters, what
`synchronous_standby_names` / `FIRST 1` mean, and how that differs from `synchronous_commit` alone.

**Hands-on:** [Lab 10 - Sync vs Async Commit](../lab/10_Sync_vs_Async_Commit.md)

**Related:** [9_Promotion.md](./9_Promotion.md) (why sync prevents ack-loss on promote),
[8_Standby_Initialization.md](./8_Standby_Initialization.md) (`primary_conninfo` / `application_name`),
[4_LSN.md](./4_LSN.md) (measuring lag and lost rows)

---

## Async vs sync (one picture)

**Async (this project's default):**

```
Client ──► Primary: COMMIT OK     ← WAL durable on primary only
           Primary ──► Standby    ← may still be in flight
```

Promote while behind → some acked commits can be **lost** on the new timeline.

**Sync:**

```
Client ──► Primary: write WAL
           Primary ──► Standby: send WAL, wait for confirmation
           Standby ──► Primary: "I have it"
Client ◄── Primary: COMMIT OK   ← only now
```

If the client got COMMIT, the named sync standby already has that WAL (to the level
`synchronous_commit` requires). Promote → those acked rows should be in `made_it`.

**Tradeoff:** sync buys durability, sells availability — COMMIT **blocks** if the sync standby cannot confirm.

---

## Two settings — both matter

| Setting                     | Job                                                     |
|-----------------------------|---------------------------------------------------------|
| `synchronous_standby_names` | **Which** standby(s) must confirm before COMMIT returns |
| `synchronous_commit`        | **How far** that standby must get (flush, apply, …)     |

### Myth to avoid

> “Just set `synchronous_commit = on` and I have sync replication.”

**False** if `synchronous_standby_names` is empty.

- Default `synchronous_commit` is often already `on`.
- With **empty** `synchronous_standby_names`, that only means: flush WAL on the **primary**.
- The primary does **not** wait for any replica → `pg_stat_replication.sync_state` stays **`async`**.

So for sync replication you **must** set `synchronous_standby_names` to match a connected standby.
Keep `synchronous_commit = on` (or stronger) for the wait level you want.

| `synchronous_commit` | Primary waits until…                                           |
|----------------------|----------------------------------------------------------------|
| `off`                | Does not even wait for local WAL flush                         |
| `local`              | WAL durable on primary only; does **not** wait for standby     |
| `remote_write`       | Standby wrote WAL to OS buffers (may not be on disk yet)       |
| `on`                 | Standby **flushed** WAL to durable storage (usual sync choice) |
| `remote_apply`       | Standby flushed **and replayed** (visible on standby queries)  |

---

## Why `application_name`?

Each standby connects with `primary_conninfo`. One field is **`application_name`** — how that standby
appears on the primary:

```sql
SELECT application_name, state, sync_state
FROM pg_stat_replication;
```

Often defaults to `walreceiver` if you never set it. You can set it explicitly:

```text
primary_conninfo = '... application_name=standby1'
```

`synchronous_standby_names` lists those **names**. The primary only waits for standbys whose
`application_name` matches the list.

```
Standby connects  →  reports application_name = walreceiver

Primary:
  synchronous_standby_names empty
       → never waits for standby → async

  synchronous_standby_names = 'FIRST 1 (walreceiver)'
       → waits for that name → sync_state = sync
```

### Two standbys → two names?

**Yes.** Give each standby its own `application_name` (e.g. `standby_a`, `standby_b`).

They should be **unique**. That is how the primary tells them apart in `pg_stat_replication` and in
`synchronous_standby_names`. Duplicate names make matching and `FIRST` / `ANY` behavior ambiguous.

---

## What `FIRST 1 (…)` means

`synchronous_standby_names` answers: **how many** sync standbys must ack, and **which** candidates.

```text
synchronous_standby_names = 'FIRST 1 (walreceiver)'
```

| Piece           | Meaning                             |
|-----------------|-------------------------------------|
| `(walreceiver)` | Candidate list (one standby here)   |
| `1`             | Wait for **one** of them to confirm |
| `FIRST`         | Prefer candidates **in list order** |

With a **single** standby, `FIRST 1 (walreceiver)` simply means: “COMMIT waits for this one sync standby.”

### More examples

```text
FIRST 1 (standby_a, standby_b)
```

Wait for **1** standby. Prefer `standby_a`; if it is gone, `standby_b` can still satisfy the “1”.

```text
FIRST 2 (standby_a, standby_b)
```

Wait for **both** before COMMIT returns.

```text
ANY 1 (standby_a, standby_b)
```

Wait for **any 1** of them (no priority order). Softens availability: one standby dying does not block forever
if the other can confirm.

Older short form still seen in docs:

```text
synchronous_standby_names = 'standby1'
```

That names one required sync standby (same idea as waiting for that name).

---

## Enable / check / disable (mental checklist)

**Enable (on primary):**

```sql
-- use the exact application_name from pg_stat_replication
ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (walreceiver)';
ALTER SYSTEM SET synchronous_commit = on;
SELECT pg_reload_conf();

SHOW synchronous_standby_names;
SELECT application_name, state, sync_state FROM pg_stat_replication;
```

**Expect:** `sync_state = sync`.

If it stays `async`, the name in `synchronous_standby_names` does not match `application_name` — fix
`primary_conninfo` on the standby, restart it, then set the matching name.

**Disable (back to async for demos that show loss):**

```sql
ALTER SYSTEM SET synchronous_standby_names = '';
SELECT pg_reload_conf();
```

---

## Sync and promotion (what changes)

| Situation                                                   | Async                                         | Sync                                                                                                                                  |
|-------------------------------------------------------------|-----------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| COMMIT returned, then promote                               | Those commits might be missing on new primary | Those commits should be on the sync standby → `made_it`                                                                               |
| Sync standby down / unreachable                             | Writes keep going                             | New COMMITs **block**                                                                                                                 |
| Insert loop keeps hitting **old** primary **after** promote | Diverges (split-brain risk)                   | Same risk — fence the old primary; sync on the old primary may even **hang** waiting for a standby that no longer exists as a replica |

👉 Sync prevents loss of **acked** commits relative to the sync standby. It does **not** replace fencing or
client cutover after promote.

---

## Takeaways

👉 Empty `synchronous_standby_names` → still async to replicas, even if `synchronous_commit = on`.

👉 `application_name` is the label the primary uses; each standby should have a unique one.

👉 `FIRST 1 (name)` = wait for one confirmation from that named candidate list (priority order).

👉 Sync: zero loss of acked commits on failover; commits can block if the sync standby cannot confirm.

---

## References

- [PostgreSQL - Synchronous Replication](https://www.postgresql.org/docs/current/warm-standby.html#SYNCHRONOUS-REPLICATION)
- [PostgreSQL - synchronous_standby_names](https://www.postgresql.org/docs/current/runtime-config-replication.html#GUC-SYNCHRONOUS-STANDBY-NAMES)
- [PostgreSQL - synchronous_commit](https://www.postgresql.org/docs/current/runtime-config-wal.html#GUC-SYNCHRONOUS-COMMIT)
- [Lab 10](../lab/10_Sync_vs_Async_Commit.md)
