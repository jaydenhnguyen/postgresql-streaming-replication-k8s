# Base Backup (`pg_basebackup`)

`pg_basebackup` is the tool that creates a **full copy of an entire PostgreSQL cluster** - every database, role, 
configuration, and WAL position - by connecting to a running `primary` over the **replication protocol**.

For streaming replication, this is how a `standby` is **seeded**: the `standby` starts life as a byte-level clone of 
the `primary`, then follows the WAL stream from the exact position where the copy was taken.

Builds on [1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md) (`PGDATA`, cluster vs database), 
[2_WAL.md](./2_WAL.md) (WAL, segments) and [4_LSN.md](./4_LSN.md) (LSN positions).

---

## What `pg_basebackup` Does

```
Primary (running, serving clients)          New Standby (empty)
┌──────────────────────────┐               ┌──────────────────────────┐
│ PGDATA/                  │               │ PGDATA/                  │
│  ├── base/       ────────┼── copy ──────►│  ├── base/               │
│  ├── global/     ────────┼── copy ──────►│  ├── global/             │
│  ├── pg_wal/     ────────┼── stream ────►│  ├── pg_wal/             │
│  └── *.conf      ────────┼── copy ──────►│  └── *.conf              │
└──────────────────────────┘               └──────────────────────────┘
        │                                          │
        └── keeps serving clients                  └── ready to start as standby
            (no downtime)
```

Typical usage (seeding a `standby`):

```bash
pg_basebackup \
  -h pg-primary \          # connect to the primary
  -U repl \                # replication role
  -D /var/lib/postgresql/data/pgdata \   # where to write the copy
  -R \                     # write standby config automatically
  -X stream \              # stream WAL during the copy
  -P                       # show progress
```

👉 The `primary` **stays online** the whole time - `pg_basebackup` is designed to run against a live, busy server.

---

## Full Cluster Copy

`pg_basebackup` copies the **entire cluster**, never a single database.

```
What we get (everything):          What we CANNOT get (selection):

✓ every database                    ✗ "just the clo835 database"
✓ all roles (users)                 ✗ "just this one table"
✓ all tablespaces                   ✗ "only rows after last week"
✓ configuration files
✓ WAL position marker
```

Why? Because replication works at the **cluster level** (see 
[1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md)):

- WAL is a single stream for the whole cluster - there is no "per-database WAL"
- A `standby` replays that stream byte-by-byte, so its starting point must be a byte-level clone of everything
- Roles and system catalogs live in `global/`, shared by all databases - a partial copy would be inconsistent

| Tool            | Granularity                              | Use case                             |
|-----------------|------------------------------------------|--------------------------------------|
| `pg_basebackup` | **Whole cluster** (physical, byte-level) | `standby` seeding, full backup       |
| `pg_dump`       | One database (logical, SQL statements)   | Selective backup/restore, migrations |

👉 **`pg_basebackup` = photocopy of the whole filing cabinet. `pg_dump` = retyping one folder's contents.**

---

## Consistent Backup

The hard problem: copying `PGDATA` **while the `primary` keeps writing to it**.

A naive file copy of a running server produces a **torn** copy:

```
Naive copy (cp -r PGDATA /backup):

t=0:00  start copying base/16384/  (table A copied)
t=0:05  primary modifies table A AND table B
t=0:10  finish copying base/16385/ (table B copied - NEWER than table A's copy!)

Result: table A = state at 0:00, table B = state at 0:10
        → the copy never existed as a real moment in time → CORRUPT
```

### How `pg_basebackup` solves it

It does not try to stop writes. Instead it uses **WAL to repair the tear**:

```
1. Ask primary for a checkpoint  → "base/ is consistent up to LSN X"
2. Record the starting LSN (X)
3. Copy all files (may be torn - that is EXPECTED and okay)
4. While copying, also collect the WAL generated during the copy (X → Y)
5. Record the ending LSN (Y)

On first startup, the new server replays WAL from X to Y
→ every torn page is overwritten with the correct version
→ the result is EXACTLY the cluster state at LSN Y
```

```
Timeline:

LSN:      X ──────────────────────────► Y
          │   file copy happens here    │
          │   (files may be torn)       │
          └── checkpoint            copy ends
              "start marker"        "end marker"

WAL from X to Y = the repair kit that makes the copy consistent
```

This is the same mechanism as crash recovery (see [2_WAL.md](./2_WAL.md)) - a base backup is essentially 
"a torn copy + enough WAL to fix it."

👉 **Consistency comes from WAL replay, not from freezing the `primary`.**

---

## Why It Runs Only Once

For a `standby`, `pg_basebackup` is the **seed**, not the ongoing sync mechanism:

```
Day 0:  pg_basebackup            → standby = clone of primary at LSN Y
Day 0+: streaming replication    → WAL Receiver + Startup Process keep it in sync
                                   (see 2_WAL.md, 4_LSN.md)

pg_basebackup is NEVER run again while replication is healthy.
```

Why not re-copy periodically?

- The WAL stream already carries **every change** - a re-copy adds nothing
- A full copy is **expensive** (all bytes over the network) vs WAL (only changes)
- Re-copying would **wipe the `standby`'s progress** and restart from scratch

### When it DOES run again

Only when the `standby` can no longer follow the WAL stream:

| Scenario                                             | Why re-seed                                     |
|------------------------------------------------------|-------------------------------------------------|
| `primary` recycled WAL the `standby` needs (no slot) | Gap in the stream - cannot replay across it     |
| Slot invalidated by `max_slot_wal_keep_size`         | Same - required WAL is gone                     |
| `standby`'s `PGDATA` corrupted/lost                  | Nothing left to resume from                     |
| `standby` diverged (e.g. was promoted by accident)   | Timelines split - byte-level clone needed again |

This is why the **initContainer must be idempotent** in a Kubernetes setup: on pod restart, if `pgdata` already 
exists (PVC survived), **skip** the copy - the `standby` resumes streaming from where it left off. Re-copying on every 
restart would be slow, wasteful, and would discard a perfectly good data directory.

```
initContainer logic:

if pgdata is empty:   run pg_basebackup   (first boot - seed)
else:                 do nothing          (restart - PVC has the data, streaming resumes)
```

👉 **Seed once, stream forever.** Re-seed only when the stream is broken beyond repair.

---

## Why It Needs a Replication Role

`pg_basebackup` connects as a database role, and that role must have the `REPLICATION` privilege:

```sql
-- On the primary
CREATE ROLE repl WITH REPLICATION LOGIN PASSWORD '...';
```

And `pg_hba.conf` must allow that role to make **replication** connections:

```
# TYPE    DATABASE        USER    ADDRESS          METHOD
  host    replication     repl    10.244.0.0/16    scram-sha-256
```

(Note: `replication` in the DATABASE column is a **keyword** matching replication connections - not a database name. 
See [1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md) `pg_hba.conf` section.)

### Why a special privilege?

Because what `pg_basebackup` asks for is far more powerful than normal SQL:

| Normal role can...                | Replication role can...                             |
|-----------------------------------|-----------------------------------------------------|
| Query tables it has access to     | Read **every byte of the entire cluster**           |
| See one database at a time        | Copy all databases, roles, configs                  |
| Be restricted by GRANTs per table | Bypass table-level permissions entirely (raw files) |

A role that can take a base backup effectively holds a copy of **everything** - passwords hashes, all data, all 
databases. That deserves its own privilege flag, a dedicated role (least privilege - the `repl` role should own 
nothing and log into nothing else), and its own `pg_hba.conf` line.

👉 **`REPLICATION` privilege = permission to read the raw cluster, not just query it.**

---

## Why It Uses the Replication Protocol

`pg_basebackup` does not speak normal SQL to the server. It uses the **replication protocol** - the same wire 
protocol WAL Senders and WAL Receivers use for streaming.

```
Normal client:               pg_basebackup / standby:

psql ──► SQL protocol        pg_basebackup ──► replication protocol
         SELECT, INSERT...                     BASE_BACKUP, START_REPLICATION...
         (rows in, rows out)                   (raw files + WAL stream out)
```

### Why not just SQL?

| Requirement                       | SQL protocol         | Replication protocol    |
|-----------------------------------|----------------------|-------------------------|
| Read raw data files (not rows)    | ✗                    | ✓ `BASE_BACKUP` command |
| Stream WAL continuously           | ✗ (request/response) | ✓ `START_REPLICATION`   |
| Coordinate start/stop LSN markers | ✗                    | ✓ built in              |
| Served by                         | Backend process      | **WAL Sender** process  |

Two practical consequences:

1. **The connection is served by a WAL Sender** - so `pg_basebackup` (and each streaming `standby`) consumes one 
   `max_wal_senders` connection on the `primary`:

   ```
   # postgresql.conf on primary
   max_wal_senders = 5   # standby(s) + pg_basebackup + spare
   ```

2. **The same credentials/path work for both jobs** - the `repl` role and the `pg_hba.conf` replication line used 
   for seeding are exactly what the `standby` then uses for streaming (`primary_conninfo`). One setup, two uses.

👉 **Seeding and streaming are the same conversation in the same language - a base backup is just the "catch up from 
zero" phase of replication.**

---

## Important Flags

```bash
pg_basebackup -h <primary-host> -U repl -D <target-dir> -R -X stream -P
```

### ✨ `-D` (directory)

Where to write the copied cluster - becomes the new server's `PGDATA`.

- Must be **empty** (or not exist) - `pg_basebackup` refuses to overwrite
- This is exactly the check an idempotent initContainer relies on

### ‼️ `-R` (write recovery config)

The flag that turns a copy into a `standby`. After the copy, it writes into the target:

```
standby.signal               ← empty file: "start in recovery mode, you are a standby"
postgresql.auto.conf         ← appended with:
  primary_conninfo = 'host=<primary-host> user=repl ...'
```

Without `-R`, the copy would start as an **independent `primary`** (a fork of the cluster). With `-R`, it starts in 
recovery mode and immediately begins streaming from the `primary`.

### ‼️ `-X stream` (how to get the WAL "repair kit")

Controls how the WAL generated **during** the copy (LSN X → Y) is obtained:

| Option      | Behavior                                                          | Risk                                                          |
|-------------|-------------------------------------------------------------------|---------------------------------------------------------------|
| `-X stream` | Open a **second connection** and stream WAL live while files copy | Safe - WAL arrives as it is made (default in modern versions) |
| `-X fetch`  | Copy WAL **after** the files finish                               | `primary` may have recycled it by then → backup fails         |
| `-X none`   | Do not include WAL                                                | Copy is not self-consistent - needs WAL from elsewhere        |

`-X stream` is the right choice for `standby` seeding: the backup is complete and consistent the moment it finishes, 
even on a busy `primary`.

### ✨ `-P` (progress)

Shows progress during the copy:

```
1234567/2345678 kB (52%), 1/1 tablespace
```

Useful for watching a long seed and for logging evidence of how long seeding takes.

---

## Putting It Together: Seeding a `standby`

```
1. Primary is up, repl role exists, pg_hba.conf allows replication connections

2. On the (empty) standby node:
     pg_basebackup -h pg-primary -U repl -D $PGDATA -R -X stream -P

3. What happened:
     - full cluster copied (base/, global/, configs...)
     - WAL from the copy window streamed alongside (-X stream)
     - standby.signal + primary_conninfo written (-R)

4. Start postgres on the standby:
     - replays WAL → reaches consistency
     - sees standby.signal → stays in recovery mode (read-only)
     - connects via primary_conninfo → streaming replication begins

5. Verify on primary:
     SELECT state, sync_state, replay_lsn FROM pg_stat_replication;
     -- one row, state = streaming
```

---

## Summary

👉 `pg_basebackup` clones the **entire cluster** (never one database) over the replication protocol, while the 
`primary` stays online.

👉 Consistency comes from **WAL replay**: torn files + WAL from the copy window (`-X stream`) = exact state at the 
end LSN.

👉 It runs **once** to seed a `standby` - after that, streaming replication carries every change. Re-seed only if the 
`standby` falls off the WAL stream or loses its data.

👉 It needs a role with the **`REPLICATION`** privilege and a `pg_hba.conf` `replication` entry - because it reads 
the raw cluster, bypassing table permissions.

👉 It speaks the **replication protocol** (served by a WAL Sender, counts against `max_wal_senders`) - seeding and 
streaming are the same mechanism.

👉 `-D` target must be empty, `-R` makes the copy a `standby` (`standby.signal` + `primary_conninfo`), `-X stream` 
ships the WAL repair kit live, `-P` shows progress.

---

## References

- [1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md) - cluster vs database, `PGDATA`, `pg_hba.conf`
- [2_WAL.md](./2_WAL.md) - WAL, crash recovery (same replay mechanism)
- [4_LSN.md](./4_LSN.md) - LSN positions
- [6_Replication_Slots.md](./6_Replication_Slots.md) - why a `standby` can fall off the stream
- [PostgreSQL Documentation - pg_basebackup](https://www.postgresql.org/docs/current/app-pgbasebackup.html)
- [PostgreSQL Documentation - Base Backup Protocol](https://www.postgresql.org/docs/current/protocol-replication.html)
