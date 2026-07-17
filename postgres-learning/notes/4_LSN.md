# Log Sequence Number (LSN)

An **LSN** is a pointer to a **byte position in the WAL stream**. Every WAL record has one - it marks exactly where 
that record sits in the log.

Think of LSNs as the ruler for replication: how far the `primary` has written, how far the `standby` has replayed, 
and how many bytes sit between them (**replication lag**).

Builds on [2_WAL.md](./2_WAL.md) (WAL records, segments) and [3_Commit_Flow.md](./3_Commit_Flow.md) (when WAL is 
written).

---

## What is an LSN?
An LSN is a **64-bit number** representing a byte offset from the beginning of the WAL stream - counting since the 
cluster was initialized.

It is displayed as two hexadecimal numbers separated by a slash:

```
0/1A2B3C40
│    │
│    └── lower 32 bits (byte offset within the "logical WAL file")
└─────── upper 32 bits (high part of the position)
```

Think of the WAL as one giant, endless tape. The LSN is the **position counter** on that tape:

```
WAL stream (conceptually one continuous tape):

byte 0 ──────────────────────────────────────────────► growing forever
                    ▲                    ▲
                LSN 0/1A2B3C40      LSN 0/1A2B3D00
                (older record)      (newer record)
```

### Key properties
- **Monotonically increasing** - a bigger LSN always means "later in the WAL stream"
- **Cluster-wide** - one LSN sequence for the entire cluster, not per database
- **Byte-accurate** - subtracting two LSNs gives an exact byte distance

👉 An LSN answers one question: **"how far into the WAL stream is this point?"**

---

## Why LSN Exists
PostgreSQL needs a precise way to talk about **progress through the WAL**:

| Question                                          | Answered by comparing LSNs                                |
|---------------------------------------------------|-----------------------------------------------------------|
| How much WAL has the `primary` written?           | `pg_current_wal_lsn()`                                    |
| How much has the `standby` received?              | `pg_last_wal_receive_lsn()`                               |
| How much has the `standby` replayed into `base/`? | `pg_last_wal_replay_lsn()`                                |
| How far behind is the `standby` (lag)?            | `pg_wal_lsn_diff()` between the two                       |
| Where does crash recovery start?                  | Last checkpoint LSN in the control file                   |
| Which WAL can be recycled?                        | Everything before the checkpoint LSN (and slot positions) |

Without LSNs, "the `standby` is a bit behind" would be a vague claim. With LSNs, it is an **exact number of bytes**.

```
Primary WAL position:   0/3000A00
Standby replay position: 0/3000000
                          ────────
Lag = pg_wal_lsn_diff() = 2560 bytes
```

👉 During a live failover, the LSN gap at promotion time tells **exactly which committed rows will be lost** - 
everything in WAL after the `standby`'s replay LSN.

---

## LSN and WAL Segments
LSNs and WAL segment filenames are directly related - the segment name encodes which LSN range it contains.

```
LSN:      0/1A2B3C40
              │
              ▼
Segment:  00000001 00000000 0000001A
          │        │        │
          │        │        └── which 16 MB slice of the stream
          │        └── high 32 bits of LSN
          └── timeline ID (not part of the LSN itself)
```

We can ask PostgreSQL which segment file holds a given LSN:

```sql
SELECT pg_walfile_name(pg_current_wal_lsn());
--       000000010000000000000003
```

```
The WAL "tape" cut into 16 MB segment files:

|── seg 001 ──|── seg 002 ──|── seg 003 ──|
0            16MB          32MB          48MB
                                  ▲
                            LSN points here
                            (inside seg 003)
```

👉 **LSN = position on the tape. Segment = which physical file that part of the tape is stored in.**

---

## The Three Key Functions
### ✨ `pg_current_wal_lsn()` - run on the `primary`

Returns the position where the `primary` is **currently writing** WAL.

```sql
-- On `primary`
SELECT pg_current_wal_lsn();
--  0/3000A00
```

This moves forward every time a transaction writes WAL (inserts, updates, commits, checkpoints...).

### ✨ `pg_last_wal_replay_lsn()` - run on the `standby`

Returns the position of the last WAL record the `standby` has **replayed into its own `base/`**.

```sql
-- On standby
SELECT pg_last_wal_replay_lsn();
--  0/3000000
```

Rows at LSNs beyond this point exist on the `primary` but are **not yet visible** on the `standby`.

### ✨ `pg_last_wal_receive_lsn()` - run on the `standby`

Returns the position of the last WAL the `standby` has **received over the network** (maybe ahead of replay).

```sql
-- On standby
SELECT pg_last_wal_receive_lsn();
--  0/3000800
```

```
The three positions during streaming:

Primary write:     0/3000A00   ← pg_current_wal_lsn()      (primary)
Standby received:  0/3000800   ← pg_last_wal_receive_lsn() (standby)
Standby replayed:  0/3000000   ← pg_last_wal_replay_lsn()  (standby)

                   ──────────────────────────────►  WAL stream
                        replayed   received   written
                            │          │         │
                            ▼          ▼         ▼
                   ─────────┼──────────┼─────────┼──►
                            │          │         │
                            └──lag─────┴─network─┘
                              (replay)   (in flight)
```

👉 "Received but not replayed" WAL is safe on the `standby`'s disk but **not yet queryable** - the Startup Process has 
not applied it to `base/` yet.

---

## Measuring Replication Lag with `pg_wal_lsn_diff()`
`pg_wal_lsn_diff(lsn_a, lsn_b)` returns **`lsn_a - lsn_b` in bytes**.

### The lag check (side by side)
```sql
-- 1. On the primary:
SELECT pg_current_wal_lsn();
--  0/3000A00

-- 2. On the standby:
SELECT pg_last_wal_replay_lsn();
--  0/3000000

-- 3. Compute the byte difference (on either node):
SELECT pg_wal_lsn_diff('0/3000A00', '0/3000000');
--  2560
```

**2560 bytes** of committed WAL exist on the `primary` that the `standby` has not yet applied. If we promoted right now, 
changes in those 2560 bytes would be **lost** on the new timeline.

### One-query version from the `primary`
The `primary` already knows the `standby`'s progress through `pg_stat_replication`:

```sql
-- On primary
SELECT client_addr,
       state,
       sync_state,
       sent_lsn,
       replay_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;
```

| Column             | Meaning                                       |
|--------------------|-----------------------------------------------|
| `sent_lsn`         | WAL sent to the `standby` so far              |
| `write_lsn`        | WAL the `standby` has written to its disk     |
| `flush_lsn`        | WAL the `standby` has fsync'd                 |
| `replay_lsn`       | WAL the `standby` has applied to `base/`      |
| `replay_lag_bytes` | **The lag number that matters for promotion** |

### Reading the output
```
replay_lag_bytes = 0          → fully caught up
replay_lag_bytes = small (KB) → normal streaming, healthy
replay_lag_bytes = growing    → standby falling behind (write burst, slow disk, network)
```

👉 Under a write loop (e.g. inserting timestamped rows), watch this number rise and fall - that is the **visible lag** 
a live demo needs to show with real numbers, not just "state = streaming".

---

## Why Lag Is Nonzero Even When Nobody Is Writing

‼️ A common surprise: the LSN gap is not always `0` even with no user writes.

**🧠 WAL is generated by more than just user transactions**:

- **Checkpoints** write CHECKPOINT records to WAL
- **Autovacuum** cleans up dead rows and logs its changes
- **Background activity** (statistics, hint bits, WAL switches)

So `pg_current_wal_lsn()` keeps creeping forward, and for a moment the `standby` is a few bytes behind until it replays.

```
No user writes, but:

Primary:  ... [CHECKPOINT] [autovacuum] ...   ← LSN still moves
Standby:  replaying a moment later            ← tiny transient gap
```

👉 A small, transient nonzero gap is **normal background WAL traffic**, not broken replication.

---

## LSN at Promotion Time (Row-Loss Accounting)
This is where LSNs stop being abstract. During **asynchronous** replication, a transaction can be:

1. Committed on the `primary`
2. Not yet received/replayed by the `standby`
3. **Lost** from the promoted `standby`'s new timeline

Promotion turns the `standby` into a new independent `primary`. It **cannot** later retrieve missing WAL from the 
old `primary`.

### Why rows get lost

The `primary` told the client "COMMIT OK" because the WAL was durable on the **`primary`'s disk**. Asynchronous 
replication does not wait for the `standby` before returning `COMMIT`:

```
Client          Primary                   Standby
  │                │                         │
  │ INSERT row 4   │                         │
  ├───────────────►│                         │
  │                │ WAL to primary disk     │
  │ COMMIT OK      │                         │
  │◄───────────────┤                         │
  │                │ --- WAL not replayed -->│
  │                │                         │
  │                │     standby promoted    │
```

"Committed" only guaranteed durability on the **old `primary`**. It did not guarantee the row had reached the `standby`.

### Example: promotion under a write load

```
Timeline of a promotion under write load:

Primary WAL:   ──[row 1]──[row 2]──[row 3]──[row 4]──[row 5]──✗ (primary gone)
                                       ▲
                     standby replay_lsn at promotion = here

Promoted standby has:  rows 1, 2, 3          (replayed before promotion)
Lost forever:          rows 4, 5             (committed on primary, never replayed)
```

| Row     | Commit WAL position | Replayed on `standby` before promotion? |
|---------|---------------------|-----------------------------------------|
| `row 1` | `0/1001000`         | Yes                                     |
| `row 2` | `0/1002000`         | Yes                                     |
| `row 3` | `0/1003000`         | Yes                                     |
| `row 4` | `0/1004000`         | **No**                                  |
| `row 5` | `0/1005000`         | **No**                                  |

- Rows committed on old `primary`: **5**
- Rows present after promotion: **3**
- Rows lost: **2**

### Received vs. replayed at promotion

Remember the three positions:

```
Primary current LSN     0/1005000
Standby receive LSN     0/1004000
Standby replay LSN      0/1003000
```

This means:

- Through `0/1003000`: received **and** applied to `standby` data
- `0/1003000`–`0/1004000`: received but not yet applied
- `0/1004000`–`0/1005000`: **never received**

🧠 When promotion runs, PostgreSQL normally **finishes replaying WAL already present locally** before completing the 
promotion. 

🧠 So the effective cut line is the `standby`'s **final replay position at promotion** - which can include 
"received but not yet replayed" WAL. Anything **never received** cannot be recovered during promotion.

### ‼️ The LSN gap does NOT tell the number of rows

This would be **incorrect**:

```
2,560 bytes behind = 5 rows lost   ✗
```

WAL includes more than row data: tuple changes, index updates, commit records, checkpoints, and other internal 
records. Use each tool for what it is good at:

| Tool                                    | What it answers                                |
|-----------------------------------------|------------------------------------------------|
| **LSNs** (`pg_wal_lsn_diff()`)          | **Why** loss occurred + how far behind (bytes) |
| **Row tags / IDs / writer's own count** | **How many** rows were lost (exact count)      |

### How to count exact row loss

Count rows by tag on the promoted node and compare against what the writer reported:

```sql
-- After promotion, on the new primary (old standby):
SELECT count(*), min(id), max(id)
FROM events
WHERE tag LIKE 'prof-word-%';
```

If the write loop reported 100 successful commits but the promoted node contains 96 matching rows:

```
100 acknowledged commits
- 96 rows on promoted node
=  4 lost rows
```

Then tie the count to the WAL state:

> "The old `primary` acknowledged 100 inserts, but the promoted `standby` contains 96. Four rows were lost because their 
> WAL had not been replayed on the `standby` before promotion. The LSN gap at promotion (replay `0/3000000` vs `primary` 
> `0/3000A00`, 2560 bytes) confirms the `standby` was behind."

### The lost rows may still exist - on the old `primary`

If the old `primary` is still alive, the "lost" rows still exist **there** - but they are absent from the **new 
`primary`'s timeline**. Writing to both nodes now would create **split-brain** (two diverging histories). How to 
prevent that: [9_Promotion.md](./9_Promotion.md).

👉 **"Some rows were lost" is not an answer. "100 sent, 96 made it, 4 lost, because the replay LSN at promotion was 
0/3000000 while the `primary` was at 0/3000A00" is an answer.**

---

## Preventing Row Loss → See 9_Promotion.md

A nonzero replay gap means asynchronous promotion may lose acknowledged writes. This note's job is to **measure and 
explain** that; the **prevention strategies** live in the promotion note:

- Synchronous replication (`synchronous_commit`) - zero loss of acked commits, but COMMIT blocks if the `standby` is down
- Promote only when lag ≈ 0 (planned failovers)
- Quorum `standbys`, replication slots, fencing the old `primary` (split-brain), HA automation

**Full walkthrough:** [9_Promotion.md](./9_Promotion.md) - "How to Prevent Data Loss During Promotion"

```
4_LSN.md:       "How do I measure and explain what survived?"
9_Promotion.md: "How do I perform promotion and prevent loss?"
```

---

## Useful LSN Commands Cheat Sheet

```sql
-- PRIMARY ---------------------------------------------------
SELECT pg_current_wal_lsn();                  -- current write position
SELECT * FROM pg_stat_replication;            -- per-standby progress
SELECT pg_walfile_name(pg_current_wal_lsn()); -- which segment file

-- STANDBY ---------------------------------------------------
SELECT pg_last_wal_receive_lsn();             -- received from network
SELECT pg_last_wal_replay_lsn();              -- applied to base/
SELECT pg_is_in_recovery();                   -- t = standby, f = primary

-- LAG (bytes) -----------------------------------------------
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)
FROM pg_stat_replication;

-- Human-readable lag
SELECT pg_size_pretty(
  pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)
) AS lag
FROM pg_stat_replication;
```

---

## Summary

👉 An **LSN** is a byte position in the WAL stream - a monotonically increasing, cluster-wide counter.

👉 `pg_current_wal_lsn()` (`primary`) = how much WAL exists; `pg_last_wal_replay_lsn()` (`standby`) = how much has been 
applied.

👉 `pg_wal_lsn_diff()` turns two LSNs into an exact **lag in bytes**.

👉 A small nonzero gap with no writers is normal - checkpoints and autovacuum generate WAL too.

👉 At promotion, the `standby`'s replay LSN is the **cut line**: WAL before it survived, committed rows after it are 
lost on the new timeline.

👉 The LSN gap explains **why** rows were lost and how far behind (bytes); row tags/counts give the **exact number** 
lost - use both together.

👉 Preventing that loss (sync replication, lag ≈ 0, fencing, split-brain) is covered in [9_Promotion.md](./9_Promotion.md).

---

## References

- [2_WAL.md](./2_WAL.md) - WAL records, segments, lifecycle
- [5_Checkpoint.md](./5_Checkpoint.md) - checkpoint LSN cut point
- [3_Commit_Flow.md](./3_Commit_Flow.md) - when WAL is written during COMMIT
- [9_Promotion.md](./9_Promotion.md) - promotion + preventing data loss
- [PostgreSQL Documentation - pg_lsn Type](https://www.postgresql.org/docs/current/datatype-pg-lsn.html)
- [PostgreSQL Documentation - System Administration Functions (WAL)](https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADMIN-BACKUP)
- [PostgreSQL Documentation - pg_stat_replication](https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-REPLICATION-VIEW)
