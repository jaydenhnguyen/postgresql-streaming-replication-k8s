# Checkpoint

A **checkpoint** is a cut point in the WAL stream. Past that point, PostgreSQL has already flushed the matching 
changes into the data files under `base/`.

In plain terms:

> "Everything before this LSN is safely in `base/`. I do not need older WAL just to recover this server."

The **Checkpointer** background process creates checkpoints.

Builds on [2_WAL.md](./2_WAL.md) (WAL lifecycle, recycling) and [3_Commit_Flow.md](./3_Commit_Flow.md) (when dirty 
pages are created).

---

## Why Checkpoints Matter

| Reason                  | Explanation                                                                       |
|-------------------------|-----------------------------------------------------------------------------------|
| **Crash recovery time** | Recovery only replays WAL *after* the last checkpoint, not the entire WAL history |
| **WAL recycling**       | Segments before the checkpoint can be safely recycled                             |
| **Consistent backup**   | `pg_basebackup` relies on checkpoint boundaries for a consistent snapshot         |

```
Timeline of WAL and checkpoints:

WAL:  |--seg1--|--seg2--|--seg3--|--seg4--|
                    ▲               ▲
              checkpoint 1    checkpoint 2
              
Recovery after crash: replay only from checkpoint 2 forward
Recycling: segments before checkpoint 2 can be reused
```

👉 Checkpoints trade **write amplification** (flushing many pages at once) for **faster recovery** and **WAL recycling**.

---

## What Does a Checkpoint Actually Write?

A checkpoint is not "just a marker." It does real disk I/O:

```
Checkpointer
     │
     ├── 1. Flush ALL dirty data pages from buffer cache → base/
     │      (table files, indexes - every modified 8 KB page)
     │
     ├── 2. Write a CHECKPOINT record into WAL (pg_wal/)
     │
     └── 3. Update the control file with the checkpoint LSN
            (so crash recovery knows where to start)
```

| What gets written   | Where                     | Purpose                                                |
|---------------------|---------------------------|--------------------------------------------------------|
| Dirty data pages    | `base/` (and tablespaces) | Make on-disk table/index files match committed changes |
| CHECKPOINT record   | `pg_wal/`                 | Mark the cut point in the WAL stream                   |
| Control file update | `global/pg_control`       | Persist "last checkpoint = LSN X" across restarts      |

**Flush** means: copy modified pages from RAM (buffer cache) to the correct files under `base/`. After flush, those 
pages in RAM become **clean** - they match what is on the disk.

```
Memory (buffer cache)          Disk
┌─────────────────┐           ┌──────────────┐
│ dirty pages     │  flush    │ base/        │
│ (changed data)  │ ────────► │ (table files)│
└─────────────────┘           └──────────────┘
         │
         │ also writes
         ▼
    pg_wal/  ← "CHECKPOINT happened at LSN X"
```

👉 A checkpoint writes **data pages** to `base/` and a **marker** to WAL - not the other way around. WAL already has 
the changes from when they were committed; the checkpoint catches `base/` up.

---

## ‼️ Checkpoint Marks a Cut Point, NOT Per-Record "Success"

A common misconception: "checkpoint marks each WAL record as done, so that WAL will never be used."

In practice, the checkpoint records a **position in the WAL stream** (an LSN):

> "At LSN `0/3000000`, all changes **before** this point are safely in `base/`."

```
WAL stream:  ... [INSERT record] [COMMIT record] ... [CHECKPOINT record at LSN X]
                      ▲                ▲                      ▲
                   your txn         durable              "base/ caught up to here"
```

After the checkpoint:

- WAL **before** LSN X is no longer needed for **this server's crash recovery** - on a crash, PostgreSQL reads the 
  control file and replays only from LSN X forward
- But that WAL may **still be needed** by a `standby`, a replication slot, or the archiver
- Eventually those old segments get **recycled** - not because they were "wrong", but because `base/` + newer WAL 
  are enough

| Wrong mental model                         | Better mental model                                         |
|--------------------------------------------|-------------------------------------------------------------|
| Checkpoint marks each WAL record "success" | Checkpoint marks a **cut point** in the WAL stream          |
| That WAL is never used again               | That WAL is not needed for **local crash recovery** anymore |
| COMMIT + checkpoint = same thing           | COMMIT = durable in WAL; checkpoint = copied to `base/`     |

‼️ Easy to confuse checkpoints with **replication slots** - both use LSNs, and both affect old WAL, but the checkpoint 
protects **this server's own crash recovery**, while a slot protects **a `standby`'s WAL supply**. See the 
"Checkpoint vs Replication Slot" section in [6_Replication_Slots.md](./6_Replication_Slots.md) for the full comparison.

---

## Configuring Checkpoints

Relevant settings live in `postgresql.conf` (or via `ALTER SYSTEM`):

```
# postgresql.conf
checkpoint_timeout = 5min      # max time between checkpoints (default)
max_wal_size = 1GB             # soft limit that forces an earlier checkpoint
min_wal_size = 80MB            # keep this much WAL for recycling
checkpoint_completion_target = 0.9   # spread checkpoint writes over most of the interval
```

| Parameter                      | What it controls                               |
|--------------------------------|------------------------------------------------|
| `checkpoint_timeout`           | Maximum time between checkpoints               |
| `max_wal_size`                 | Soft WAL size that triggers a checkpoint early |
| `min_wal_size`                 | How much recycled WAL to keep ready            |
| `checkpoint_completion_target` | How aggressively to spread flush I/O (0.0–1.0) |

View current values:

```sql
SHOW checkpoint_timeout;
SHOW max_wal_size;
SHOW checkpoint_completion_target;

SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name LIKE 'checkpoint%' OR name IN ('max_wal_size', 'min_wal_size')
ORDER BY name;
```

---

## ‼️ What `checkpoint_timeout = 5min` Does NOT Mean

A common misconception:

> "Every modified page stays in RAM for exactly 5 minutes, then gets written."

**That is wrong.**

### What it actually means

PostgreSQL guarantees a checkpoint will occur **no later than 5 minutes after the previous checkpoint** (unless 
another trigger fires earlier - see next section).

Dirty pages are flushed during the **next checkpoint**, not 5 minutes after each individual `UPDATE`/`INSERT`.

A page modified at second 1 and a page modified at second 4:59 of the same interval are both flushed together when 
that checkpoint runs - they do **not** each get their own 5-minute timer.

### Timeline example

```
t=0:00   Checkpoint #1 completes
         Timer starts: next checkpoint by t=5:00 at latest

t=0:30   UPDATE page A  → page A becomes dirty in RAM
         (no flush yet - WAL already has the change from COMMIT)

t=2:00   INSERT page B  → page B becomes dirty in RAM

t=4:00   UPDATE page A again → page A still dirty (newer version in RAM)

t=5:00   checkpoint_timeout expires
         Checkpoint #2 runs:
           - flush page A → base/
           - flush page B → base/
           - write CHECKPOINT record
           - update control file

         Page A was dirty for ~4.5 minutes
         Page B was dirty for ~3 minutes
         Neither waited "exactly 5 minutes from its own UPDATE"
```

```
Time ─────────────────────────────────────────────────────────────►
0:00          0:30     2:00              4:00         5:00
 │             │        │                 │            │
 CKPT #1    UPDATE A  INSERT B         UPDATE A     CKPT #2
                                                         │
                                          flush A + B together
```

👉 **`checkpoint_timeout` is a deadline between checkpoints, not a per-page TTL.**

---

## When Does a Checkpoint Occur?

A checkpoint occurs whenever **either** of these happens first:

1. **`checkpoint_timeout` expires** — time-based trigger
2. **`max_wal_size` is reached** — WAL-volume trigger

Plus a few other triggers:

| Trigger                        | Type      | Notes                                        |
|--------------------------------|-----------|----------------------------------------------|
| `checkpoint_timeout` expires   | Automatic | Guarantees a checkpoint at least this often  |
| `max_wal_size` reached         | Automatic | Checkpoint fires **early** if WAL grows fast |
| `CHECKPOINT;`                  | Manual    | Admin-requested                              |
| Clean shutdown (`pg_ctl stop`) | Shutdown  | Final flush before exit                      |

### OR logic in practice

```
Checkpoint #1 done
        │
        ├── clock ticking toward checkpoint_timeout (e.g. 5 min)
        └── WAL growing toward max_wal_size (e.g. 1 GB)

Whichever limit is hit FIRST → Checkpoint #2 starts
```

**Busy write workload:**

```
t=0:00  Checkpoint #1
t=1:30  WAL hits max_wal_size  → Checkpoint #2 fires early
        (timeout would have waited until t=5:00)
```

**Quiet workload:**

```
t=0:00  Checkpoint #1
t=5:00  timeout expires         → Checkpoint #2 fires on schedule
        (WAL never approached max_wal_size)
```

👉 Think of it as: **checkpoint at least every N minutes, or sooner if WAL fills up.**

---

## ‼️ `max_wal_size` vs `checkpoint_timeout`

Both trigger checkpoints. They are **not** two names for the same thing - they are two different **limits**, and 
whichever is hit **first** wins.

|                         | `checkpoint_timeout`                         | `max_wal_size`                                      |
|-------------------------|----------------------------------------------|-----------------------------------------------------|
| **Unit**                | Time (e.g. `5min`)                           | Size (e.g. `1GB`)                                   |
| **Question it answers** | "How long can I wait between checkpoints?"   | "How much WAL may pile up before I checkpoint?"     |
| **Trigger**             | Clock expires                                | Estimated WAL between checkpoints grows too large   |
| **Quiet workload**      | Usually wins (timeout fires on schedule)     | Rarely reached                                      |
| **Busy write workload** | Often loses to the size limit                | Usually wins (checkpoint fires **early**)           |
| **What it does NOT do** | Does not cap disk usage by itself            | Does not guarantee "keep this much WAL forever"     |

```
After Checkpoint #1:

  Time budget ──────────► checkpoint_timeout (e.g. 5 min)
  Size budget ──────────► max_wal_size (e.g. 1 GB)

         ┌─ quiet DB: time budget runs out first
         │
Checkpoint #2 fires when EITHER budget is used up
         │
         └─ busy DB: size budget runs out first (early checkpoint)
```

**How to read the stats:**

```sql
SELECT checkpoints_timed,   -- hit checkpoint_timeout
       checkpoints_req      -- hit max_wal_size / CHECKPOINT / etc.
FROM pg_stat_bgwriter;
```

- Mostly `checkpoints_timed` → time limit is in charge (typical quiet/moderate load)
- Mostly `checkpoints_req` → WAL is growing fast; size limit is forcing early checkpoints

**Tuning intuition:**

- Raise `max_wal_size` → fewer early checkpoints under load, but **longer crash recovery** (more WAL to replay) and 
  more WAL on disk between checkpoints
- Lower `checkpoint_timeout` → more frequent time-based checkpoints, shorter recovery windows, more flush I/O

👉 **`checkpoint_timeout` = time ceiling. `max_wal_size` = size ceiling. Same outcome (a checkpoint), different 
meters.**

For how `max_wal_size` differs from **retaining** WAL for standbys, see 
[`max_wal_size` vs `wal_keep_size`](./2_WAL.md) in [2_WAL.md](./2_WAL.md).

---

## Background Writer vs Checkpointer

PostgreSQL has **two** processes that write dirty pages to disk. They look similar but have different jobs.

|                                 | Background Writer                       | Checkpointer                                      |
|---------------------------------|-----------------------------------------|---------------------------------------------------|
| **When**                        | Continuously, in small batches          | Periodically (timeout / max_wal_size / manual)    |
| **How many pages**              | A few dirty pages at a time             | **All** dirty pages needed for the checkpoint     |
| **Goal**                        | Keep free buffers available; smooth I/O | Create a recovery cut point; enable WAL recycling |
| **Writes a CHECKPOINT record?** | No                                      | **Yes**                                           |
| **Updates control file?**       | No                                      | **Yes**                                           |
| **Enables WAL recycling?**      | No                                      | **Yes**                                           |
| **Crash recovery impact**       | Helps a little (fewer dirty pages left) | **Defines** where recovery starts                 |

```
Between checkpoints:

Background Writer ──► gently writes some dirty pages → base/
                      (reduces I/O spike at next checkpoint)

At checkpoint time:

Checkpointer ──► flushes remaining dirty pages → base/
            ──► writes CHECKPOINT record → pg_wal/
            ──► updates control file
```

### Why both exist

Without the Background Writer, every checkpoint would suddenly flush a huge pile of dirty pages → disk I/O spike → 
query latency spikes.

With the Background Writer, many pages are already clean by checkpoint time, so the Checkpointer has less work left.

```
Without bgwriter:     [==== huge I/O spike at checkpoint ====]
With bgwriter:        [--gentle--][--gentle--][=smaller spike=]
```

👉 **Background Writer = continuous housekeeping. Checkpointer = the official "base/ is safe up to this LSN" event.**

Only the Checkpointer creates the recovery cut point. The Background Writer cannot replace it.

---

## How Checkpoint Relates to Crash Recovery

When PostgreSQL starts after an unclean shutdown, recovery starts from the **last checkpoint LSN** (see 
[2_WAL.md](./2_WAL.md) Crash Recovery section):

```
1. INSERT row → WAL record written → COMMIT acknowledged
2. Checkpointer has NOT yet flushed the page to base/
3. Server crashes
4. On restart:
   - Read last checkpoint (before the INSERT)
   - Replay WAL → find INSERT record → redo the insert
   - Row is restored even though base/ was never updated
```

👉 Checkpoint = "base/ is safe up to here." Everything after that LSN must be replayed from WAL.

---

## Viewing Checkpoint Information

```sql
SELECT *
FROM pg_control_checkpoint();
```

Checkpoint activity stats:

```sql
SELECT checkpoints_timed,      -- triggered by checkpoint_timeout
       checkpoints_req,        -- triggered by max_wal_size / CHECKPOINT / etc.
       checkpoint_write_time,
       checkpoint_sync_time,
       buffers_checkpoint,     -- pages written by Checkpointer
       buffers_clean           -- pages written by Background Writer
FROM pg_stat_bgwriter;
```

👉 If `checkpoints_req` is much higher than `checkpoints_timed`, WAL is growing fast - consider raising 
`max_wal_size` (or accepting more frequent checkpoints).

---

## Summary

👉 A **checkpoint** flushes dirty pages to `base/`, writes a CHECKPOINT record, and updates the control file.

👉 `checkpoint_timeout = 5min` means "checkpoint no later than 5 minutes after the last one" - **not** "each page 
stays dirty for exactly 5 minutes."

👉 A checkpoint fires when **either** `checkpoint_timeout` expires **or** `max_wal_size` is reached (whichever first) - 
time ceiling vs size ceiling, same outcome, different meters.

👉 **`max_wal_size` ≠ `wal_keep_size`.** One forces a checkpoint; the other is a soft WAL cushion for standbys. Full 
comparison: [2_WAL.md](./2_WAL.md).

👉 **Background Writer** gently flushes some dirty pages between checkpoints; **Checkpointer** creates the recovery 
cut point.

👉 WAL before the checkpoint is no longer needed for **local** recovery - but may still be needed by `standbys`/slots.

👉 Checkpoint ≠ replication slot. Full comparison: [6_Replication_Slots.md](./6_Replication_Slots.md).

---

## References

- [2_WAL.md](./2_WAL.md) - WAL lifecycle, recycling, `max_wal_size` vs `wal_keep_size`
- [3_Commit_Flow.md](./3_Commit_Flow.md) - INSERT → dirty page → COMMIT → checkpoint
- [6_Replication_Slots.md](./6_Replication_Slots.md) - Checkpoint vs Replication Slot
- [PostgreSQL Documentation - Checkpoints](https://www.postgresql.org/docs/current/wal-configuration.html)
- [PostgreSQL Documentation - WAL](https://www.postgresql.org/docs/current/wal-intro.html)
- [PostgreSQL Documentation - Background Writer](https://www.postgresql.org/docs/current/runtime-config-resource.html#GUC-BGWRITER-DELAY)
