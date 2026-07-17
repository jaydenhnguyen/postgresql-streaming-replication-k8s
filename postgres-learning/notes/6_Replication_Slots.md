# Replication Slots

👉 A **replication slot** is just a tiny piece of metadata that PostgreSQL stores to remember a replication 
consumer's progress.

👉 It records **how far that consumer has progressed** through the WAL stream, so the `primary` knows which WAL 
segments it must **not recycle yet**.

👉 Without a slot, the `primary` recycles WAL based only on its own needs (checkpoints) - and can throw away WAL a 
lagging `standby` still needs, breaking replication permanently.

Builds on [2_WAL.md](./2_WAL.md) (WAL recycling), [5_Checkpoint.md](./5_Checkpoint.md) (local recovery cut point), 
and [4_LSN.md](./4_LSN.md) (LSN positions).

---

## What is a Replication Slot?

The problem it solves:

```
Without a slot:

Primary:  "Checkpoint done. I don't need segments 001-005 anymore. Recycle!"
Standby:  "Wait... I still need segment 003..."
Primary:  "Too late. It's gone."
Standby:  ✗ replication broken → must re-seed with pg_basebackup
```

A replication slot fixes this by making the `standby`'s progress **visible and binding** on the `primary`:

```
With a slot:

Slot "standby1": restart_lsn = 0/3000000  ← standby confirmed up to here
Primary:  "Checkpoint done... but slot standby1 still needs WAL from 0/3000000.
           I will keep those segments."
```

### Key behaviors

- The slot stores the **LSN position** the consumer has confirmed (received/flushed)
- The `primary` **retains all WAL** at or after that position - recycling is blocked past it
- The slot **persists across restarts** of both `primary` and `standby`
- The slot **persists even if the `standby` disconnects** - that is both its power and its danger (see Disk Full Risk)

👉 A slot is a **contract**: "do not recycle WAL past this consumer's position, no matter what."

---

## ‼️ Checkpoint vs Replication Slot

Both use LSNs and both affect old WAL, but they solve **completely different problems**:

- **Checkpoint:** protects the PostgreSQL server **itself** during crash recovery.
- **Replication slot:** protects a **replication consumer** from losing WAL it has not consumed.

|                       | Checkpoint                                         | Replication slot                                    |
|-----------------------|----------------------------------------------------|-----------------------------------------------------|
| Main purpose          | Make local data files recoverable                  | Keep WAL for a standby/consumer                     |
| Tracks                | Local server's recovery position                   | Consumer's WAL progress                             |
| Concerned with        | Dirty pages and `base/`                            | WAL retention for replication                       |
| Created by            | PostgreSQL automatically                           | Administrator/configuration                         |
| Position              | Checkpoint/redo LSN                                | `restart_lsn`                                       |
| Stored in             | Control file + WAL record                          | `pg_replslot/<slot>/state`                          |
| Does it copy data?    | Flushes dirty pages to `base/`                     | No                                                  |
| Blocks WAL recycling? | Determines what **local recovery** no longer needs | Prevents recycling WAL still needed by **consumer** |

### Checkpoint asks: "Does my own `base/` have the data?"

```
WAL:  [row1][row2][row3][row4][row5]
                         ▲
                    checkpoint
```

The checkpoint flushes dirty pages to the `primary`'s own `base/`. Afterward: "my local data files contain everything 
up to here; crash recovery can start from this point." It never asks whether the `standby` received anything.

### Slot asks: "Has my standby consumed the WAL?"

```
Primary WAL:

[row1][row2][row3][row4][row5]
             ▲          ▲
        slot position   checkpoint/current progress
```

The checkpoint may say the `primary` itself no longer needs old WAL - but the slot says "the standby is only at row2, 
do not recycle past that." The `primary` retains row3-row5 so the standby can catch up.

### How they work together

```
Checkpoint recovery position: 0/5000000
Slot restart_lsn:             0/3000000

WAL stream:

0/1000000────0/3000000────0/5000000────0/6000000
                  ▲             ▲             ▲
             slot needs     checkpoint      current
             WAL here       progressed      position

Can recycle       Must retain for standby
◄───────────┤──────────────────────────────────►
```

The **oldest remaining requirement wins**. When the standby catches up (slot moves to `0/5900000`), the older 
segments become recyclable.

### Analogy: teacher and whiteboard

- **WAL** = everything written on the whiteboard
- **Checkpoint** = teacher copied the board into the official notebook (`base/`)
- **Replication slot** = a student says, "I have only copied up to this line - don't erase the rest yet"

The teacher may already have everything in the official notebook, but still cannot erase the board because the 
student is behind. Once the student catches up, the old board content can be erased/reused.

### Neither replaces the other

| Scenario                     | Consequence                                                               |
|------------------------------|---------------------------------------------------------------------------|
| Checkpoint without a slot    | Old WAL recycled → slow standby misses WAL → re-seed with `pg_basebackup` |
| Slot without monitoring      | Dead standby → slot never moves → `pg_wal/` grows → disk fills            |
| Checkpoint replacing a slot? | No - checkpoint only knows about **local** recovery, not standbys         |
| Slot replacing a checkpoint? | No - slot only pins WAL, it never flushes dirty pages to `base/`          |

👉 **Checkpoint says: "My local data files are safe up to this recovery point." Slot says: "This consumer still 
needs WAL from this earlier point - do not recycle it."**

---

## Physical Replication Slot

A **physical slot** tracks a consumer of the raw, byte-level WAL stream - exactly what streaming replication uses.

This is the type used for a `standby` (and for `pg_basebackup`):

```sql
-- Create on the PRIMARY
SELECT pg_create_physical_replication_slot('standby1_slot');
```

The `standby` references it in its connection settings (written into `postgresql.auto.conf` by `pg_basebackup -R`, or 
set manually):

```
primary_conninfo   = 'host=pg-primary ... user=repl ...'
primary_slot_name  = 'standby1_slot'
```

Now, when the WAL Receiver connects, the `primary`'s WAL Sender attaches to the slot and updates its position as the 
`standby` confirms receipt.

### Monitoring

```sql
-- On the PRIMARY
SELECT slot_name,
       slot_type,
       active,
       restart_lsn,
       pg_size_pretty(
         pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
       ) AS retained_wal
FROM pg_replication_slots;
```

| Column         | Meaning                                                          |
|----------------|------------------------------------------------------------------|
| `slot_type`    | `physical` (streaming `standby`) or `logical`                    |
| `active`       | `t` = a consumer is currently connected using this slot          |
| `restart_lsn`  | Oldest WAL position this slot still needs - recycling stops here |
| `retained_wal` | How much WAL the `primary` is holding **because of this slot**   |

👉 `active = f` with a growing `retained_wal` is the warning sign: the consumer is gone but the slot still holds WAL.

---

## Logical Replication Slot

A **logical slot** decodes WAL into **row-level changes** (INSERT/UPDATE/DELETE as logical events) instead of raw 
bytes. Used for:

- Logical replication (`CREATE PUBLICATION` / `CREATE SUBSCRIPTION`)
- Change Data Capture (CDC) tools like Debezium
- Selective replication (specific tables, not the whole cluster)

```
Physical slot:  WAL bytes ──────────────► standby replays bytes  (whole cluster)
Logical slot:   WAL bytes → decoded → "INSERT INTO events VALUES (...)"  (per table)
```

|             | Physical slot              | Logical slot                     |
|-------------|----------------------------|----------------------------------|
| Granularity | Entire cluster             | Per database / tables            |
| Consumer    | `standby`, `pg_basebackup` | Subscriptions, CDC tools         |
| Use case    | HA / failover              | Data integration, selective sync |

👉 For streaming replication and failover, **physical** slots are the relevant type. Logical slots are a separate 
topic to learn later.

---

## Slot Metadata

A slot stores only **bookkeeping data**, not WAL itself:

```
Slot "standby1_slot" (conceptually):
│
├── slot_name:    standby1_slot
├── slot_type:    physical
├── restart_lsn:  0/3000000     ← oldest WAL this consumer still needs
├── active:       t             ← currently connected?
└── ...
```

The actual WAL bytes stay in `pg_wal/` - the slot just **pins** them there by holding an LSN position.

---

## `pg_replslot/` Directory

Slot metadata lives on disk inside `PGDATA`, one subdirectory per slot:

```
PGDATA/
│
├── pg_wal/          ← the WAL segments themselves
└── pg_replslot/     ← slot metadata (NOT WAL)
    ├── standby1_slot/
    │   └── state    ← small binary file with the slot's position
    └── analytics_slot/
        └── state
```

- Tiny files (bytes, not megabytes)
- Survive restarts - this is why slots persist
- Deleting a slot's directory by hand is **not** the way to remove it; use `pg_drop_replication_slot()`

👉 `pg_replslot/` answers "where does the `primary` remember each consumer's position" - it does **not** store WAL.

---

## Slot vs WAL

Easy to confuse - they are different things with different jobs:

|                         | WAL (`pg_wal/`)                            | Slot (`pg_replslot/`)                    |
|-------------------------|--------------------------------------------|------------------------------------------|
| **Contains**            | The actual change records (16 MB segments) | A position (LSN) per consumer            |
| **Size**                | Large (MBs-GBs)                            | Tiny (bytes)                             |
| **Purpose**             | Durability, recovery, replication data     | Track consumer progress, block recycling |
| **Growth**              | Grows with write activity                  | Fixed size                               |
| **Danger if unmanaged** | -                                          | Pins WAL forever → disk fills            |

Relationship in one line:

```
The slot (bookmark) tells the primary which WAL (pages of the book) it must keep.
```

👉 **Slot = bookmark. WAL = the book.** The bookmark is small, but it prevents the book's pages from being torn out.

---

## Slowest `standby` Rule

With multiple consumers, the `primary` must keep WAL for the **slowest** one:

```
WAL stream:  ───────────────────────────────────────►
                  ▲                    ▲
            slot "reporting"      slot "standby1"
            restart_lsn =         restart_lsn =
            0/1000000 (SLOW)      0/5000000 (fast)

Primary must retain ALL WAL from 0/1000000 onward
                    └── the slowest slot decides
```

- WAL retention is driven by `min(restart_lsn)` across **all** slots
- One slow (or dead) consumer forces the `primary` to hoard WAL for everyone
- The fast `standby` being caught up does not help - the slowest bookmark wins

👉 **The slowest consumer dictates how much WAL the `primary` keeps.** Monitor every slot, not just the busiest `standby`.

---

## ‼️ Disk Full Risk

The slot's persistence is a double-edged sword. If a consumer **dies and never comes back**, its slot keeps pinning 
WAL **forever**:

```
Day 1:  standby dies. Slot "standby1_slot" stays at restart_lsn = 0/3000000
Day 2:  primary keeps writing WAL... retained: 2 GB
Day 5:  retained: 20 GB
Day 9:  pg_wal/ fills the disk
        → primary cannot write WAL
        → primary STOPS ACCEPTING WRITES (or crashes)
```

An abandoned slot can take down the **primary** - the healthy node - which is worse than the original `standby` failure.

### Protections

| Protection                           | What it does                                                                                |
|--------------------------------------|---------------------------------------------------------------------------------------------|
| **Monitor `pg_replication_slots`**   | Alert on `active = f` or growing retained WAL                                               |
| **`max_slot_wal_keep_size`** (PG13+) | Cap on WAL a slot may retain; beyond it the slot is invalidated instead of filling the disk |
| **Drop dead slots**                  | `SELECT pg_drop_replication_slot('standby1_slot');`                                         |

```
# postgresql.conf on primary - safety cap
max_slot_wal_keep_size = 10GB
```

With the cap, a runaway slot gets **invalidated** (its `standby` must be re-seeded with `pg_basebackup`), but the 
`primary` keeps running:

```sql
-- Check if a slot was invalidated
SELECT slot_name, wal_status, safe_wal_size
FROM pg_replication_slots;
-- wal_status: reserved | extended | unreserved | lost
--                                              └── slot invalidated
```

👉 **Tradeoff triangle:** no slot = `standby` may fall off the stream; slot without cap = `primary` disk may fill; slot 
with `max_slot_wal_keep_size` = bounded risk on both sides.

---

## Configuring Slots: `max_replication_slots`

`max_replication_slots` sets **how many replication slots the server can have at once**

```
# postgresql.conf on primary
max_replication_slots = 10     # default
```

```
max_replication_slots = 10

pg_replslot/ "parking lot":
[slot 1][slot 2][slot 3][ empty ][ empty ][ empty ][ empty ][ empty ][ empty ][ empty ]
   ▲        ▲       ▲
standby1  backup  analytics
```

### What it does (and does not do)

|              |                                                                            |
|--------------|----------------------------------------------------------------------------|
| **Does**     | Cap the total number of slots (physical + logical combined) that can exist |
| **Does**     | Reserve a little shared memory per slot at server start                    |
| **Does NOT** | Limit how much WAL each slot retains (that is `max_slot_wal_keep_size`)    |
| **Does NOT** | Create any slots by itself - slots are still created explicitly            |

If all slots are used, creating another one fails:

```sql
SELECT pg_create_physical_replication_slot('one_too_many');
-- ERROR:  all replication slots are in use
-- HINT:   Free one or increase "max_replication_slots".
```

### Key facts

- **Requires a restart** to change - PostgreSQL allocates slot bookkeeping in shared memory at startup, so plan a 
  sensible value up front
- Must be **at least the number of `standbys`/consumers** you expect, plus headroom for temporary slots 
  (`pg_basebackup` can use a temporary slot during seeding)
- Also matters on a **standby** if it will serve cascading replication or be promoted (the promoted node needs slot 
  capacity for its own `standbys`)
- Setting it to `0` disables slot creation entirely

### How it relates to the other slot settings

```
max_replication_slots   → HOW MANY slots can exist        (count)
max_slot_wal_keep_size  → HOW MUCH WAL a slot may pin     (size cap)
max_wal_senders         → HOW MANY streaming connections  (walsender processes)
```

These are separate limits. A typical two-node setup with headroom:

```
# postgresql.conf on primary
max_wal_senders        = 5     # streaming connections (standby + pg_basebackup + spare)
max_replication_slots  = 5     # slot parking spaces
max_slot_wal_keep_size = 10GB  # per-slot WAL retention cap
```

Check usage:

```sql
SHOW max_replication_slots;

SELECT count(*) AS slots_used
FROM pg_replication_slots;
```

👉 `max_replication_slots` is a **capacity** setting (how many bookmarks the `primary` can hold), not a **retention** 
setting (how much WAL each bookmark pins - that is `max_slot_wal_keep_size`).

---

## Useful Commands Cheat Sheet

```sql
-- Create a physical slot (on PRIMARY)
SELECT pg_create_physical_replication_slot('standby1_slot');

-- List slots + how much WAL each one pins
SELECT slot_name, slot_type, active, restart_lsn, wal_status,
       pg_size_pretty(
         pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
       ) AS retained_wal
FROM pg_replication_slots;

-- Drop a slot (must not be active)
SELECT pg_drop_replication_slot('standby1_slot');
```

```
# Standby side - use the slot (postgresql.auto.conf / -R output)
primary_slot_name = 'standby1_slot'
```

---

## Summary

👉 A **replication slot** is the `primary`'s bookmark of a consumer's WAL position - it blocks recycling past that 
point.

👉 **Physical** slots serve streaming `standbys` (raw WAL bytes); **logical** slots decode row-level changes (CDC, 
logical replication).

👉 Slots store **metadata only** (tiny `state` files in `pg_replslot/`) - the WAL itself stays in `pg_wal/`.

👉 **Slot = bookmark, WAL = the book.** The bookmark keeps pages from being torn out.

👉 The **slowest slot** dictates WAL retention for the whole `primary`.

👉 An abandoned slot can **fill the `primary`'s disk and stop writes** - monitor slots and set 
`max_slot_wal_keep_size` as a safety cap.

👉 `max_replication_slots` caps **how many** slots can exist (restart required); `max_slot_wal_keep_size` caps 
**how much WAL** each slot may pin.

---

## References

- [2_WAL.md](./2_WAL.md) - WAL recycling, what prevents it
- [5_Checkpoint.md](./5_Checkpoint.md) - checkpoint cut point (local recovery)
- [4_LSN.md](./4_LSN.md) - LSN positions, lag measurement
- [PostgreSQL Documentation - Replication Slots](https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION-SLOTS)
- [PostgreSQL Documentation - pg_replication_slots](https://www.postgresql.org/docs/current/view-pg-replication-slots.html)
- [PostgreSQL Documentation - Replication Functions](https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-REPLICATION)
