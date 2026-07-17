# Write-Ahead Logging (WAL)

WAL is how PostgreSQL makes sure a committed transaction survives a crash. Every change is written to the WAL 
**before** the matching data files on disk are updated.

WAL also unlocks:
- **Crash recovery** - replay changes after a crash
- **Streaming replication** - ship the same WAL from a `primary` to a `standby`
- **Point-in-Time Recovery (PITR)** - restore to a chosen moment using archived WAL

Without WAL, crash recovery and streaming replication would not work.

👉 WAL is **cluster-wide** - one stream for the whole cluster, not one per database.

---

## Why WAL Exists?
PostgreSQL keeps frequently accessed data pages in **shared memory (buffer cache)** for performance. When a transaction
modifies a row, the change happens in memory first - the on-disk data file in `base/` is **not** updated immediately.

This creates a problem: if the server crashes before the in-memory page is written to disk, the committed change would 
be lost.

WAL solves this with the **write-ahead rule**:

```
1. Write the change to WAL on disk first
2. Acknowledge the commit to the client
3. Flush the data page to disk later (at checkpoint)
```

This guarantees **durability** (**the D in ACID**). Even if the server crashes between steps 2 and 3, PostgreSQL can 
replay the WAL on restart and reconstruct every committed transaction.

### What WAL enables?
| Use case              | How WAL helps                                                       |
|-----------------------|---------------------------------------------------------------------|
| Crash recovery        | Replay WAL from the last checkpoint to restore committed work       |
| Streaming replication | WAL Sender reads the same WAL files and streams them to a `standby` |
| PITR                  | Archive WAL segments and replay up to a target timestamp or LSN     |
| Backup consistency    | `pg_basebackup` uses WAL to produce a consistent cluster snapshot   |

Example of the durability guarantee:
```
Client                          PostgreSQL
  │                                 │
  │  INSERT INTO events ...         │
  ├────────────────────────────────►│
  │                                 │  1. Generate WAL record
  │                                 │  2. WAL Writer flushes to pg_wal
  │                                 │  3. Return COMMIT to client
  │◄────────────────────────────────┤
  │                                 │
  │         (server crashes)        │
  │                                 X
  │                                 │
  │         (server restarts)       │
  │                                 │  4. Replay WAL from checkpoint
  │                                 │  5. Row is restored
```

👉 Committed data is safe because the commit record exists in WAL on disk, even if the data file was never updated.

---

## WAL vs. Data Files
PostgreSQL stores information in two fundamentally different places:
```
PGDATA/
│
├── base/          ← Data Files (table and index contents)
└── pg_wal/        ← WAL Files (record of every modification)
```

|                | WAL (`pg_wal/`)                   | Data Files (`base/`)         |
|----------------|-----------------------------------|------------------------------|
| **Contains**   | Sequential log of changes         | Actual table and index pages |
| **Written by** | WAL Writer (on every commit)      | Checkpointer (periodically)  |
| **Format**     | Append-only log segments          | Fixed-size pages (8 KB)      |
| **Purpose**    | Durability, recovery, replication | Long-term storage of data    |
| **Updated**    | Immediately on commit             | Lazily at checkpoint         |

### The write-ahead rule in practice
When a `backend process` executes:
```sql
INSERT INTO events (tag) VALUES ('jaydenhnguyen-demo-1');
```

PostgreSQL does **NOT** immediately write the new row into the table file under `base/`. Instead:

```
Backend Process
      │
      ▼
Generate WAL record
(describes the INSERT)
      │
      ▼
   WAL Writer
      │
      ▼
    pg_wal/          ← written FIRST (write-ahead)
      │
      ▼
(Checkpointer flushes later)
      │
      ▼
base/16384/...   ← written LATER
```

👉 **WAL is the source of truth for recent changes.** Data files are a cached, on-disk representation that may lag 
behind WAL.

👉 During streaming replication, the `standby` receives **WAL**, **not copies** of `base/` files. The `standby`'s Startup 
Process replays WAL to update its own `base/` files.

---

## ‼️ INSERT + COMMIT: Step-by-Step Flow

This is the most important mental model for understanding WAL, checkpoints, and replication lag.

**Read the full walkthrough:** [3_Commit_Flow.md](./3_Commit_Flow.md)

Covers:
- Three places data lives (`base/`, `pg_wal/`, RAM)
- Full `INSERT` + `COMMIT` flow (steps 1–6)
- Dirty vs clean pages
- Why the client sees `COMMIT` before `base/` is updated
- How this connects to `standby` replication

---

## WAL Record
A **WAL record** is the smallest unit of information written to the WAL. Each record describes a single atomic change 
to the database.

Examples of changes that produce WAL records:
- Inserting, updating, or deleting a row
- Creating or dropping a table
- Committing or aborting a transaction
- Creating a checkpoint

### What a WAL record contains
Each record carries metadata that allows PostgreSQL to replay the change:

- **LSN (Log Sequence Number)** - unique byte offset identifying this record's position in the WAL stream
- **Transaction ID (XID)** - which transaction made the change
- **Resource Manager ID** - what type of object was modified (heap, btree, etc.)
- **Change data** - enough information to redo (or undo) the operation

Example concept:
```
WAL Record
│
├── LSN: 0/1A2B3C40
├── XID: 742
├── Type: INSERT
├── Table: events (OID 16385)
└── Data: row values
```

👉 WAL records are generated by `backend processes` and buffered in shared memory before the **WAL Writer** flushes 
them to disk.

👉 Every committed transaction has at least one WAL record - the **commit record** - which is what makes the 
transaction durable.

---

## WAL Segment
WAL records are not written to individual files per transaction. They are grouped into fixed-size files called 
**WAL segments**.

### Default segment size
By default, each WAL segment is **16 MB**. This is controlled by `wal_segment_size`, set at cluster initialization time.

```
pg_wal/
│
├── 000000010000000000000001    ← 16 MB segment
├── 000000010000000000000002    ← 16 MB segment
├── 000000010000000000000003    ← 16 MB segment
└── ...
```

### Segment naming
WAL segment filenames are 24 hexadecimal characters:
```
TTTTTTTTXXXXXXXXXXXXXXXX
│        │
│        └── Log sequence number within the timeline
└── Timeline ID
```

Example:
```
000000010000000000000001
```

- Timeline `00000001` - the cluster's timeline (increments after promotion/failover)
- Log `00000000` + offset `00000001` - position within that timeline

### When segments fill up
PostgreSQL appends WAL records sequentially into the current segment. When a segment reaches 16 MB, PostgreSQL switches 
to the next segment file.

```
Segment 000...001  [████████████████████] full
Segment 000...002  [████░░░░░░░░░░░░░░░░] active
```

👉 Streaming replication ships data at the WAL record level, but storage and archiving work at the **segment** level 
(entire 16 MB files).

---

## WAL Directory (`pg_wal`)
All WAL segments are stored in the `pg_wal/` directory inside `PGDATA`.

```
PGDATA/
│
├── base/
├── global/
├── pg_wal/              ← all WAL segments live here
│   ├── 000000010000000000000001
│   ├── 000000010000000000000002
│   └── archive_status/  ← tracks segments pending archive
├── pg_replslot/
└── ...
```

### Key properties

- **Append-only** - new records are always appended; existing segments are never modified in place
- **Shared across the cluster** - WAL for all databases is written to the same `pg_wal/` directory
- **Critical for replication** - the WAL Sender on the `primary` reads from this directory to stream to standbys

### Useful commands
✨ Check the current WAL write position:
```sql
SELECT pg_current_wal_lsn();
```

✨ List WAL directory contents from the shell:
```bash
ls -lh $PGDATA/pg_wal/
```

✨ Check WAL-related settings:
```sql
SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name LIKE 'wal%'
ORDER BY name;
```

✨ Important settings:

| Parameter       | Purpose                                                            |
|-----------------|--------------------------------------------------------------------|
| `wal_level`     | How much information WAL records (`minimal`, `replica`, `logical`) |
| `max_wal_size`  | Soft limit before forcing a checkpoint                             |
| `min_wal_size`  | Minimum WAL to retain for recycling                                |
| `wal_keep_size` | Minimum WAL to retain for standbys (if no slot)                    |


✨ For streaming replication, `wal_level` must be at least `replica`:
```sql
SHOW wal_level;
-- replica
```

👉 `pg_wal/` is one of the most important directories in `PGDATA`. Losing it while the server is running can make crash 
recovery impossible.

---

## WAL Lifecycle
A WAL record moves through several stages from SQL execution to disk persistence.

### Full lifecycle
```
Client SQL
     │
     ▼
Backend Process
(generates WAL records
 into WAL buffers
 in shared memory)
     │
     ▼
WAL Writer
(flushes WAL buffers
 to pg_wal/ on disk)
     │
     ▼
Commit acknowledged
 to client
     │
     ▼
WAL Sender (Primary only)
(reads pg_wal/ and
 streams to standby)
     │
     ▼
Checkpointer
(flushes dirty data
 pages to base/)
     │
     ▼
WAL Recycling
(old segments reused
 or archived)
```

### Step-by-step
1. **Generate** - Backend Process creates WAL records in shared-memory WAL buffers
2. **Flush** - WAL Writer writes buffers to the current segment in `pg_wal/`
3. **Commit** - A commit WAL record is flushed; the client receives confirmation
4. **Stream** - WAL Sender (on `primary`) reads new WAL and sends it to connected standbys
5. **Checkpoint** - Checkpointer writes dirty pages to `base/` and records a checkpoint in WAL
6. **Recycle** - Segments older than the checkpoint can be reused or archived

### WAL buffers
Before reaching disk, WAL records sit in **WAL buffers** (shared memory). The WAL Writer flushes them based on:
- A commit (must flush before acknowledging the commit)
- WAL buffer filling up
- The `wal_writer_delay` timer

```
Shared Memory
│
├── Buffer Cache (data pages)
└── WAL Buffers (WAL records)
         │
         ▼
    WAL Writer
         │
         ▼
      pg_wal/
```

👉 The client only sees `COMMIT` after the commit WAL record is safely on disk - not after the data file is updated.

---

## WAL Recycling
PostgreSQL cannot keep every WAL segment forever - the disk would fill up. After a **checkpoint**, WAL segments that are no
longer needed can be **recycled**.

### Recycled ≠ deleted

Recycling is **not** throwing the file in the trash. It is:

1. PostgreSQL decides: "I do not need the segment `001` anymore"
2. **Renames** it to a future segment number (e.g. `001` → `010`)
3. **Overwrites** it later when that segment number is needed again

```
Before recycle:
pg_wal/
├── 000...001  (old, no longer needed)
├── 000...002
├── 000...003  (active)

After recycle:
pg_wal/
├── 000...002
├── 000...003  (active)
├── 000...010  ← this IS the old 001, renamed and ready to reuse
```

The file slot is reused, not thrown away. That is why `pg_wal/` usually stays a stable size instead of growing forever.

### Why rename and reuse instead of just deleting?

**🧠 Deleting and creating files is slow** 

**🧠 renaming is fast**.

WAL rotation happens on the hot path - while transactions are committing. Commit latency should not spike because the 
OS is allocating a new 16 MB file.

```
delete old file  →  filesystem removes metadata, frees blocks     (slow)
create new file  →  filesystem allocates metadata, reserves 16 MB (slow)

rename file      →  metadata-only operation, same disk blocks     (fast)
```

👉 **Recycle = rename + reuse disk space.** It avoids slow file create/delete on every WAL rotation and keeps a 
pre-sized pool ready for the next writing burst.

### Why recycle if the `standby` already has it?

The `standby` does **not** need the `primary` to keep a copy of old WAL forever.

```
Primary's job:  generate WAL → stream to standby → eventually free disk space
Standby's job:  receive WAL → replay into its own base/ → keep its own copy
```

🧠 Once a checkpoint has flushed data to `base/` on the `primary` **and** all consumers (standbys, slots, archiver) have 
passed that WAL position, the `primary` no longer needs those old segments. The `standby` already applied them into **its 
own** data directory.

```
Timeline:

Primary pg_wal:  [seg1][seg2][seg3][seg4]
                      ▲ checkpoint here

After checkpoint + standby caught up:
  seg1, seg2 → recycled (primary disk freed)
```

### When recycling happens
Usually after a **checkpoint**, for WAL **before** the checkpoint position:

```
Before checkpoint:
pg_wal/
├── 000...001  (needed)
├── 000...002  (needed)
├── 000...003  (needed)
└── 000...004  (active)

After checkpoint (position recorded at 000...002):
pg_wal/
├── 000...001  → recycled (renamed and reused)
├── 000...002  (needed - checkpoint is here)
├── 000...003  (needed)
└── 000...004  (active)
```

Segments before the checkpoint can be recycled because `base/` already has that data on disk - unless something still 
needs that WAL (see below).

### What prevents recycling
| Mechanism                             | Effect                                                             |
|---------------------------------------|--------------------------------------------------------------------|
| **Replication slot**                  | Retains WAL until the slowest consumer (`standby`) has replayed it |
| **`wal_keep_size`**                   | Forces the `primary` to keep a minimum amount of WAL for standbys  |
| **`archive_mode = on`**               | WAL must be archived before recycling                              |
| **Long-running queries on `standby`** | Can delay WAL removal if `hot_standby_feedback` is enabled         |

###  ‼️  Risk: WAL removed before `standby` catches up
If a `standby` falls too far behind and the `primary` recycles WAL segments the `standby` still needs, replication breaks. 
**The `standby` must be re-seeded with `pg_basebackup`.**

```
Primary                          Standby
  │                                 │
  │  WAL segments 001–010           │  still needs segment 003
  │  checkpoint at 010              │
  │  recycles 001–005               │  ✗ segment 003 gone
  │                                 │
  │                                 └── replication broken
```

👉 **Replication slots** exist specifically to prevent this - they tell the `primary` "do not recycle WAL past this 
point."

---

## ‼️ Checkpoint

Checkpoint details live in their own note - flush to `base/`, cut-point LSN, triggers, and how checkpoints differ 
from replication slots:

**Read the full walkthrough:** [5_Checkpoint.md](./5_Checkpoint.md)

---

## Crash Recovery

When PostgreSQL starts after an unclean shutdown (crash, `kill -9`, power loss), it enters **crash recovery** mode 
before accepting connections.

### Recovery process
```
Server starts
     │
     ▼
Read control file
(find last checkpoint position)
     │
     ▼
Replay WAL forward
from checkpoint LSN
     │
     ▼
Redo every WAL record
not yet reflected in data files
     │
     ▼
Database consistent
(accept connections)
```

### What recovery guarantees
- **Committed transactions are preserved** - their commit records are in WAL
- **Uncommitted transactions are rolled back** - their changes are undone during replay
- **No committed data is lost** - as long as WAL reached disk before the crash

### Example scenario
```
1. INSERT row → WAL record written → COMMIT acknowledged
2. Checkpointer has NOT yet flushed the page to base/
3. Server crashes
4. On restart:
   - Read last checkpoint (before the INSERT)
   - Replay WAL → find INSERT record → redo the insert
   - Row is restored even though base/ was never updated
```

### Recovery on a `standby`
A `standby` runs recovery **continuously** - it is always in recovery mode, replaying incoming WAL from the `primary`. 
This is why standbys are read-only:

```sql
SELECT pg_is_in_recovery();
-- t  (on standby)
-- f  (on primary, after promotion)
```

👉 Crash recovery and `standby` WAL replay use the **same mechanism** - reading WAL records and redoing changes. The 
difference is the source: local `pg_wal/` after a crash vs. network stream from the `primary`.

---

## Summary

👉 WAL records every database change **before** data files are updated (write-ahead rule). See [3_Commit_Flow.md](./3_Commit_Flow.md) for the full `INSERT` + `COMMIT` walkthrough.

👉 WAL records are grouped into **16 MB segments** stored in `pg_wal/`.

👉 The **WAL Writer** flushes WAL to disk; the **Checkpointer** flushes data pages to `base/` - see [5_Checkpoint.md](./5_Checkpoint.md).

👉 **Crash recovery** replays WAL from the last checkpoint to restore committed work.

👉 **Streaming replication** ships the same WAL from `primary` to `standby` - the `standby`'s Startup Process replays it.

👉 If WAL is recycled before a `standby` receives it, replication breaks and the `standby` must be re-seeded with `pg_basebackup`.

---

## References

- [3_Commit_Flow.md](./3_Commit_Flow.md) - INSERT + COMMIT walkthrough
- [5_Checkpoint.md](./5_Checkpoint.md) - checkpoints, cut-point LSN, recycling
- [6_Replication_Slots.md](./6_Replication_Slots.md) - slots vs checkpoints
- [PostgreSQL Documentation - WAL](https://www.postgresql.org/docs/current/wal-intro.html)
- [PostgreSQL Documentation - WAL Internals](https://www.postgresql.org/docs/current/wal-internals.html)
- [PostgreSQL Documentation - Continuous Archiving and Point-in-Time Recovery](https://www.postgresql.org/docs/current/continuous-archiving.html)
- [Medium - PostgreSQL Architecture](https://medium.com/@sumeet.k.shukla/postgresql-architecture-6df259dc1145)
