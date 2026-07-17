# `standby` Initialization

After `pg_basebackup` seeds the data directory (see [7_Base_Backup.md](./7_Base_Backup.md)), what makes the new 
server start as a **standby** instead of a normal `primary`? Two things:

1. **`standby.signal`** - a file that says "start in recovery mode"
2. **`primary_conninfo`** - a setting that says "here is where to stream WAL from"

This note walks through both, the exact startup sequence, what recovery mode means, and how to check a server's role 
with `pg_is_in_recovery()`.

Builds on [7_Base_Backup.md](./7_Base_Backup.md) (seeding) and [2_WAL.md](./2_WAL.md) (WAL replay).

---

## The Two Ingredients

A freshly seeded data directory is a **byte-level clone of the `primary`**. If just started PostgreSQL on it, it 
would come up as another independent `primary` (a fork). The `standby` behavior comes from:

```
PGDATA/  (on the standby, after pg_basebackup -R)
│
├── standby.signal          ← "I am a standby. Start in recovery mode."   (WHO AM I)
├── postgresql.auto.conf    ← primary_conninfo = '...'                    (WHO DO I FOLLOW)
├── base/                   ← cloned data
├── pg_wal/                 ← WAL from the copy window
└── ...
```

| Ingredient         | Question it answers       | Without it                                                     |
|--------------------|---------------------------|----------------------------------------------------------------|
| `standby.signal`   | "Am I a `standby`?"       | Server starts as a normal read-write `primary`                 |
| `primary_conninfo` | "Where do I get new WAL?" | `standby` replays local WAL, then waits forever (no streaming) |

👉 `pg_basebackup -R` writes **both** - that is the whole job of the `-R` flag.

---

## `standby.signal`

An **empty file** in the root of `PGDATA`. Its **presence** is the entire message:

```bash
ls $PGDATA/standby.signal
# the file exists → server starts in recovery mode as a standby
# content does not matter (it is empty)
```

### What it changes at startup

| At startup, PostgreSQL checks... | File present                                     | File absent                      |
|----------------------------------|--------------------------------------------------|----------------------------------|
| Role                             | `standby` (recovery mode)                        | `primary` (normal mode)          |
| Writes                           | Rejected (read-only)                             | Accepted                         |
| WAL                              | **Replayed** (from local `pg_wal/`, then stream) | **Generated** (by user activity) |
| Recovery ends when...            | **Never** (continuous recovery)                  | After crash recovery completes   |

### Promotion removes it

When a `standby` is promoted (`pg_ctl promote` or `pg_promote()`), PostgreSQL **deletes `standby.signal`** and exits 
recovery mode. That is why promotion is one-way: the "I am a `standby`" marker is gone, the server starts a new 
timeline, and it begins **generating** WAL instead of replaying it.

```
Before promotion:  PGDATA/standby.signal exists  → replaying WAL, read-only
After promotion:   PGDATA/standby.signal deleted → generating WAL, read-write
```

👉 **`standby.signal` is a role marker, not configuration.** One empty file decides whether the server replays WAL 
forever or serves writes.

---

## `primary_conninfo`

A connection string telling the `standby` **how to reach the `primary`** for streaming:

```
# postgresql.auto.conf (written by pg_basebackup -R)
primary_conninfo = 'host=pg-primary-0.pg-primary-hs port=5432 user=repl password=... application_name=standby1'
```

| Part               | Meaning                                                                               |
|--------------------|---------------------------------------------------------------------------------------|
| `host` / `port`    | Where the `primary` listens (in Kubernetes: the **stable headless-Service DNS name**) |
| `user`             | The replication role (`repl`) - same one `pg_basebackup` used                         |
| `password`         | Its password (can also come from `~/.pgpass` or environment)                          |
| `application_name` | How this `standby` shows up in `pg_stat_replication` on the `primary`                 |

### Who uses it

The **WAL Receiver** process reads `primary_conninfo`, connects to the `primary` (a WAL Sender picks up the call), and 
streams WAL continuously (see [1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md) process roles).

```
Standby                                   Primary
WAL Receiver ──primary_conninfo──► WAL Sender
      │                                  │
      └── writes WAL to local pg_wal/    └── reads WAL from its pg_wal/
```

### Optional companion: `primary_slot_name`

```
primary_slot_name = 'standby1_slot'
```

Tells the `primary` which **replication slot** this `standby` consumes - so the `primary` retains WAL for it (see 
[6_Replication_Slots.md](./6_Replication_Slots.md)).

👉 **`standby.signal` = "I am a `standby`." `primary_conninfo` = "This is my `primary`."** Together they turn a clone 
into a follower.

---

## `standby` Startup Sequence

What happens, in order, when PostgreSQL starts on a seeded data directory:

```
1. postgres (parent) starts, reads configs, opens PGDATA
        │
        ▼
2. Sees standby.signal
        │  "recovery mode - I am a standby"
        ▼
3. Startup Process begins replaying LOCAL WAL
        │  (the WAL that -X stream packed into pg_wal/ during seeding)
        │  → reaches a consistent state
        ▼
4. Consistency reached → hot standby opens for READ-ONLY queries
        │
        ▼
5. Local WAL exhausted → WAL Receiver starts
        │  connects using primary_conninfo
        ▼
6. Streaming replication established
        │  WAL Receiver writes incoming WAL → Startup Process replays it
        ▼
7. Steady state: continuous replay, read-only queries allowed
        (primary now shows this standby in pg_stat_replication)
```

Two details worth remembering:

- **Local WAL first, network second.** The `standby` replays what it already has on disk before asking the `primary` for 
  more. On a pod restart with a surviving PVC, this is why no re-seed is needed - it replays local WAL, then 
  reconnects and catches up.
- **The Startup Process never finishes.** On a crashed `primary`, recovery ends when local WAL runs out. On a `standby`, 
  recovery is **continuous** - it just keeps waiting for more WAL. That is the only real difference.

👉 `standby` startup = crash recovery that never ends, followed by a network subscription for more WAL.

---

## Recovery Mode

**Recovery mode** means: the server is applying WAL records instead of generating them from user writes.

|                                   | `primary` (normal mode)              | `standby` (recovery mode)     |
|-----------------------------------|--------------------------------------|-------------------------------|
| WAL                               | Generates it (from writes)           | Replays it (from the stream)  |
| Writes (INSERT/UPDATE/DELETE/DDL) | Accepted                             | **Rejected**                  |
| Reads (SELECT)                    | Allowed                              | Allowed (**hot `standby`**)   |
| Processes                         | Backends, WAL Writer, WAL Senders... | Startup Process, WAL Receiver |

### Why the `standby` is read-only

The `standby`'s `base/` must stay an exact product of the `primary`'s WAL stream. If local writes were allowed, the 
`standby`'s state would diverge, and incoming WAL would no longer apply cleanly:

```sql
-- On the standby
INSERT INTO events (tag) VALUES ('test');
-- ERROR:  cannot execute INSERT in a read-only transaction
```

That error is the expected proof that the `standby` is doing its job. Reads are fine - they do not change data:

```sql
-- On the standby
SELECT count(*) FROM events;   -- works (hot standby)
```

👉 **Recovery mode = replay-only.** The one source of truth for changes is the `primary`'s WAL stream; local writes 
would poison it.

---

## `pg_is_in_recovery()`

The one-query role check:

```sql
SELECT pg_is_in_recovery();
```

| Result | Meaning                                                                     |
|--------|-----------------------------------------------------------------------------|
| `t`    | This server is in recovery mode → **`standby`** (replaying WAL, read-only)  |
| `f`    | This server is not in recovery → **`primary`** (generating WAL, read-write) |

### The promotion flip

This function is how we **prove** a promotion worked:

```sql
-- Before promotion (on standby)
SELECT pg_is_in_recovery();   -- t

-- Promote:  pg_ctl promote -D $PGDATA   (or SELECT pg_promote();)

-- After promotion (same server)
SELECT pg_is_in_recovery();   -- f   ← standby.signal deleted, recovery exited
```

```
        pg_is_in_recovery()
Standby ────────► t
   │
   │ pg_ctl promote
   ▼
New primary ────► f      (one-way - it will not flip back to t)
```

The flip is **one-way**: returning this server to `standby` duty requires re-seeding it as a new clone (new 
`pg_basebackup`, new `standby.signal`).

👉 **`t` = follower, `f` = leader.** After a promotion, seeing `f` plus a successful `INSERT` is the definitive 
proof the `standby` became a real `primary`.

Full promotion walkthrough (methods, data-loss prevention, fencing): [9_Promotion.md](./9_Promotion.md).

---

## Putting It Together: From Seed to Streaming

```
pg_basebackup -h pg-primary -U repl -D $PGDATA -R -X stream
        │
        ├── clones the cluster into $PGDATA
        ├── writes standby.signal            (role: standby)
        └── writes primary_conninfo          (target: primary)

start postgres
        │
        ├── sees standby.signal → recovery mode
        ├── replays local WAL → consistent → read-only queries OK
        ├── WAL Receiver connects via primary_conninfo
        └── streaming replication established

verify:
        standby:  SELECT pg_is_in_recovery();                        -- t
        primary:  SELECT state, replay_lsn FROM pg_stat_replication; -- streaming
        standby:  INSERT ...;                                        -- ERROR read-only (expected!)
```

---

## Summary

👉 A seeded clone becomes a `standby` because of two things: **`standby.signal`** (role marker: start in recovery) and 
**`primary_conninfo`** (where to stream WAL from). `pg_basebackup -R` writes both.

👉 Startup sequence: see `standby.signal` → replay **local** WAL → open read-only (hot `standby`) → WAL Receiver 
connects via `primary_conninfo` → continuous streaming replay.

👉 **Recovery mode** = replay-only: WAL comes from the `primary`, local writes are rejected 
("cannot execute INSERT in a read-only transaction").

👉 **`pg_is_in_recovery()`**: `t` = `standby`, `f` = `primary`. Promotion deletes `standby.signal` and flips it to `f` - 
one-way.

👉 On restart with an intact data directory, the `standby` resumes (local WAL → reconnect); no re-seed needed - which 
is exactly why the seeding step must be skipped when `pgdata` already exists.

---

## References

- [7_Base_Backup.md](./7_Base_Backup.md) - seeding, the `-R` flag
- [9_Promotion.md](./9_Promotion.md) - promote standby → primary, prevent data loss
- [2_WAL.md](./2_WAL.md) - WAL replay, crash recovery
- [1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md) - Startup Process, WAL Receiver, WAL Sender
- [6_Replication_Slots.md](./6_Replication_Slots.md) - `primary_slot_name`
- [PostgreSQL Documentation - Hot Standby](https://www.postgresql.org/docs/current/hot-standby.html)
- [PostgreSQL Documentation - Standby Server Settings](https://www.postgresql.org/docs/current/runtime-config-replication.html#RUNTIME-CONFIG-REPLICATION-STANDBY)
