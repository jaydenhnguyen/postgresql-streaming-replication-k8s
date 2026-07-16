# INSERT + COMMIT: Step-by-Step Flow

This note walks through exactly what happens when a user commits a change - for example, an `INSERT`. 

It ties together concepts from [1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md) (processes, `base/`, buffer cache) and 
[2_WAL.md](./2_WAL.md) (write-ahead logging, checkpoints).

## 🧠 **The key idea:**
- `base/` on disk is where actual table data lives long-term. 
- PostgreSQL does **not** write there on every `COMMIT`. 
- It writes to **WAL first**, keeps the change in **RAM** for a while, then copies it to `base/` later at a 
**checkpoint**.

---

## Three Places Data Lives
```
┌─────────────────────────────────────────────────────────┐
│  DISK (PGDATA)                                          │
│                                                         │
│  pg_wal/          ← the LOG (journal of changes)        │
│  base/            ← the REAL DATA (table pages)         │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  RAM (shared memory)                                    │
│                                                         │
│  buffer cache     ← copies of data pages, fast to change│
└─────────────────────────────────────────────────────────┘
```

| Location           | What it is                                              |
|--------------------|---------------------------------------------------------|
| `base/`            | Real table files on disk - rows eventually end up here  |
| `pg_wal/`          | Append-only log - every change is recorded here first   |
| RAM (buffer cache) | Working copy of pages - inserts change pages here first |

👉 **`base/` is the long-term home for table data.** WAL and RAM are how Postgres gets there safely and fast.

---

## The SQL We Are Tracing
```sql
INSERT INTO events (tag) VALUES ('jayden-demo');
COMMIT;
```

Everything below follows this one insert through to disk.

---

## Step 1 - Client Sends SQL
```
Client  ──►  Backend Process (one per connection)
```

The **backend process** is the process that runs the SQL. One backend is created for each client connection.

---

## Step 2 - Find the Right Data Page
The table `events` is stored as 8 KB **pages** in a file under `base/`.

```
base/16384/16385   ← file for table "events" (example path)
```

PostgreSQL needs the page that will hold this row:
- If that page is already in RAM → use it
- If not → read it from `base/` into RAM (buffer cache)

```
DISK base/          RAM buffer cache
┌──────────┐        ┌──────────┐
│ page 5   │  read  │ page 5   │
│ (old)    │ ─────► │ (copy)   │
└──────────┘        └──────────┘
```

---

## Step 3 - Change Happens in RAM (Page Becomes "Dirty")
The backend adds the new row to **the page in RAM**.

```
RAM buffer cache
┌──────────────────────┐
│ page 5               │
│  row 1: old          │
│  row 2: old          │
│  row 3: jayden-demo  │  ← NEW (only in RAM so far)
└──────────────────────┘
        │
        └── page is now "dirty" (RAM ≠ disk)
```

**Important:** `base/` on disk still has the **old** page. No row has been written to the table file yet.

### 📝 What is a dirty page?
A **data page** is a **fixed 8 KB block** that holds some table rows. PostgreSQL reads pages into the **buffer cache** 
(RAM) for speed.

| Term           | Meaning                                                       |
|----------------|---------------------------------------------------------------|
| **Clean page** | In memory and matches what is on disk in `base/`              |
| **Dirty page** | In memory and **changed**, but **not yet written** to `base/` |

```
INSERT happens:

  RAM (buffer cache)          Disk (base/)
  ┌──────────────┐           ┌──────────────┐
  │ page with    │           │ page WITHOUT │
  │ new row      │  dirty!   │ new row yet  │
  │ (dirty)      │           │              │
  └──────────────┘           └──────────────┘
```

👉 A **dirty page** is the gap between "change happened" and "table file on disk was updated."

---

## Step 4 - WAL Record Is Created (in RAM First)

At the same time, PostgreSQL writes a **WAL record** describing the insert:

```
WAL record (conceptually):
  "At LSN 0/1A2B3C, transaction 742, INSERT into events, row = jayden-demo"
```

This goes into **WAL buffers** in RAM (**not disk yet**).

The backend process generates WAL records; the **WAL Writer** will flush them later.

---

## Step 5 - `COMMIT`: WAL Must Hit Disk Before a Client Gets OK

When `COMMIT`, PostgreSQL **must** flush the WAL (including the commit record) to `pg_wal/` on disk.

```
RAM                         DISK
┌─────────────┐            ┌─────────────┐
│ WAL buffers │  flush     │ pg_wal/     │
│ INSERT rec  │ ────────►  │ segment ... │
│ COMMIT rec  │            │ (on disk)   │
└─────────────┘            └─────────────┘
```

Only **after** that flush succeeds:

```
Client  ◄──  "COMMIT" (success)
```

👉 **The client does NOT wait for `base/` to be updated.** **It waits only for WAL on the disk**.

### State at the moment the client sees COMMIT

| Location             | Has the new row? |
|----------------------|------------------|
| RAM (dirty page)     | yes              |
| `pg_wal/`            | yes (logged)     |
| `base/` (table file) | **not yet**      |

So: **committed in the database's eyes**, but the table file on disk may still be stale.

👉 **COMMIT means "WAL is on disk."** It does **not** mean "row is in `base/` yet."

---

## Step 6 - Later: Checkpoint Flushes Dirty Page to `base/`

Sometime later (seconds to minutes), the **Checkpointer** runs and writes dirty pages from RAM to disk.

```
RAM (dirty page)              DISK base/
┌──────────────────┐          ┌──────────────────┐
│ page 5           │  flush   │ page 5           │
│  + jayden-demo   │ ───────► │  + jayden-demo   │
└──────────────────┘          └──────────────────┘
```

Now `base/` actually contains the row on disk. The page in RAM is now **clean** (matches disk).

### What happens to the WAL after this?

The checkpoint does **not** mark the `INSERT`'s WAL record as "success" and throw it away. It records a **position** 
(LSN) in the WAL stream:

> "At LSN x, everything **before** this point is safely in `base/`."

After that:

| For...                           | Old WAL (before LSN X) is...                                   |
|----------------------------------|----------------------------------------------------------------|
| **This server's crash recovery** | No longer needed - recovery replays only from LSN X forward    |
| **Standby replication**          | Possibly still needed - kept until the standby has replayed it |
| **Disk space**                   | Eventually **recycled** (renamed + reused), not deleted        |

See [2_WAL.md - Checkpoint](./2_WAL.md#checkpoint) for the cut-point mental model, and 
[2_WAL.md - WAL Recycling](./2_WAL.md#wal-recycling) for why segments are renamed and reused instead of deleted.

---

## Visual Timeline

```
Time ──────────────────────────────────────────────────────────────►

INSERT in RAM          COMMIT                    Checkpoint
(dirty page)           (WAL to disk)             (base/ updated)
     │                      │                          │
     ▼                      ▼                          ▼

RAM:  [new row]         [new row]                  [new row]
WAL:  [buffered]        [ON DISK ✓]                [ON DISK ✓]
base: [old data]        [old data]                 [new row ON DISK ✓]

Client:                 "COMMIT OK" ←── happens here
```

---

## Why Not Write to `base/` Immediately on COMMIT?

1. **Speed** - appending to WAL is sequential and fast; updating random table pages is slower
2. **Durability is cheaper** - one small WAL flush proves the transaction is safe
3. **Batching** - checkpoint writes many dirty pages at once instead of one disk write per row

If the server crashes **after COMMIT** but **before checkpoint**:

- `base/` might not have the row
- `pg_wal/` **does** have the insert + commit
- On restart, PostgreSQL **replays WAL** and applies the insert again → row is restored

👉 WAL is the safety net until `base/` catches up. That is the whole point of write-ahead logging.

---

## How This Connects to Replication

On a **standby**, the same replay mechanism applies - but the WAL arrives over the network from the primary instead of 
from local `pg_wal/` after a crash:

```
Primary                         Standby
  │                                │
  │  INSERT → WAL on disk          │
  │  COMMIT to client              │
  │                                │
  │  WAL Sender streams WAL ──────►│  WAL Receiver
  │                                │  Startup Process replays
  │                                │  → updates standby's base/
```

This is why replication lag is measured in **LSN bytes** - the standby may have received WAL but not yet replayed it 
into its `base/` files. That gap is exactly what matters during promotion and row-loss accounting.

---

## Summary

👉 `base/` is where tables really live on disk.

👉 On `COMMIT`, PostgreSQL only guarantees the change is in `pg_wal/` - not in `base/` yet.

👉 The insert first changes a **dirty page** in RAM.

👉 The **Checkpointer** later flushes dirty pages to `base/`.

👉 If the server crashes after COMMIT but before checkpoint, WAL replay restores the row.

---

## References

- [1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md) — processes, `PGDATA`, `base/`
- [2_WAL.md](./2_WAL.md) — WAL segments, lifecycle, checkpoint, crash recovery
- [PostgreSQL Documentation — WAL](https://www.postgresql.org/docs/current/wal-intro.html)
