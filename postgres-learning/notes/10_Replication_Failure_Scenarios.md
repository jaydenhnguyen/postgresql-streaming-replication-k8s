# Replication Failure Scenarios

Streaming replication breaks when something sits between "`primary` writes WAL" and "`standby` receives and replays 
it." This note covers common failures, how they look, how to diagnose them, and how to recover.

Builds on [2_WAL.md](./2_WAL.md) (recycling), [6_Replication_Slots.md](./6_Replication_Slots.md) (slots), 
[7_Base_Backup.md](./7_Base_Backup.md) (re-seed), and [4_LSN.md](./4_LSN.md) (lag).

---

## The Healthy Baseline

Before failures, know what "healthy" looks like:

```sql
-- On primary
SELECT application_name, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
-- Expect: one row, state = 'streaming', lag_bytes small/stable

-- On standby
SELECT pg_is_in_recovery();                 -- t
SELECT pg_last_wal_receive_lsn();
SELECT pg_last_wal_replay_lsn();            -- close to receive_lsn
```

```
Primary ──WAL stream──► Standby
  WAL Sender active       WAL Receiver + Startup Process active
  pg_stat_replication     continuous replay
  has 1 streaming row
```

Every failure below breaks some part of this path.

---

## 1. Network Partition

The `primary` and `standby` can no longer talk to each other (network cut, firewall, wrong DNS, Service misconfig).

```
Primary                    Standby
  │                           │
  │  ✗ TCP connection gone    │
  │                           │
  WAL Sender: waits / times   WAL Receiver: reconnect loop
  out, disconnects            (cannot reach primary_conninfo)
```

### What you see

| Where                           | Symptom                                                         |
|---------------------------------|-----------------------------------------------------------------|
| `primary` `pg_stat_replication` | Row **disappears** (or `state` not `streaming`)                 |
| `standby` logs                  | Connection refused / timeout to `primary_conninfo`              |
| `standby` queries               | Still serve **old** data (read-only, frozen at last replay LSN) |
| `primary`                       | Keeps accepting writes normally (async)                         |

### Why it is dangerous

Under async replication, the `primary` keeps committing. WAL piles up. When the network returns:

- **With a replication slot:** `primary` retained WAL → `standby` catches up (may take time)
- **Without a slot:** `primary` may have recycled the WAL the `standby` needs → **permanent break** (see WAL Removed)

### Recovery

1. Fix the network / DNS / `pg_hba.conf` / Service
2. Confirm `standby` reconnects: `pg_stat_replication` shows `streaming` again
3. Watch lag shrink with `pg_wal_lsn_diff`
4. If reconnect fails with "requested WAL segment has already been removed" → rebuild (section 6)

👉 Network partition itself does not destroy data - **what the `primary` does with WAL while the `standby` is cut off** 
does.

---

## 2. `standby` Offline

The `standby` process or pod is stopped, crashed, or deleted - but the `primary` is fine.

```
Primary                          Standby
  │                                 ✗ down
  │  WAL Sender: no consumer
  │  (slot still holds position if configured)
```

### What you see

| Where                            | Symptom                                                                       |
|----------------------------------|-------------------------------------------------------------------------------|
| `primary` `pg_stat_replication`  | Empty (no streaming `standby`)                                                |
| `primary` `pg_replication_slots` | Slot may still exist with `active = f`                                        |
| `primary` disk                   | If slot exists → `pg_wal/` **grows** (WAL retained for the offline `standby`) |

### Two outcomes depending on slots

| Setup            | While `standby` is offline               | When `standby` returns                                  |
|------------------|------------------------------------------|---------------------------------------------------------|
| **With slot**    | `primary` keeps WAL from `restart_lsn`   | `standby` streams missing WAL and catches up            |
| **Without slot** | `primary` recycles WAL after checkpoints | `standby` may find required WAL **gone** → must rebuild |

### ‼️ Disk risk with a slot

An offline `standby` + an active slot can fill the `primary` disk (see 
[6_Replication_Slots.md](./6_Replication_Slots.md) Disk Full Risk). Cap it:

```
max_slot_wal_keep_size = 10GB
```

### Recovery

1. Bring the `standby` back (restart pod / process)
2. Confirm reconnect and lag catch-up
3. If WAL was recycled / slot invalidated → rebuild with `pg_basebackup`

👉 **`standby` offline is survivable with a slot (and a WAL size cap). Without a slot, long downtime often means a 
rebuild.**

---

## 3. WAL Removed

The `primary` recycled (or deleted) WAL segments the `standby` still needs.

```
Primary pg_wal/:  [seg 010][seg 011][seg 012]  ← recycled 001-009
Standby still needs:              seg 003
                                  ✗ gone forever
```

### What you see

`standby` logs (classic message):

```
FATAL:  could not receive data from WAL stream:
ERROR:  requested WAL segment 000000010000000000000003 has already been removed
```

Or on reconnect:

```
ERROR:  replication slot ... is invalid because the required WAL was deleted
-- (when max_slot_wal_keep_size invalidated the slot)
```

`primary`: `pg_stat_replication` empty; `standby` stuck in reconnect / crash loop.

### Why it happens

| Cause                        | Mechanism                                              |
|------------------------------|--------------------------------------------------------|
| No replication slot          | Checkpoint recycled WAL past what the `standby` needed |
| `wal_keep_size` too small    | Soft retention ran out (see section 5)                 |
| `max_slot_wal_keep_size` hit | Slot invalidated to protect `primary` disk             |
| `standby` offline too long   | Same as above - retention exhausted                    |

### Recovery

**There is no catch-up.** Missing WAL cannot be invented. The only fix:

→ **Rebuild the `standby` with `pg_basebackup`** (section 6)

👉 **"WAL removed" = hard failure.** Diagnosis is confirmation; recovery is always a re-seed.

---

## 4. Missing Replication Slot

Either no slot was ever configured, or the slot was dropped / never referenced by the `standby`.

```
# Standby missing this → primary does not retain WAL for it
primary_slot_name = 'standby1_slot'
```

### What you see

```sql
-- On primary
SELECT * FROM pg_replication_slots;
-- empty, or no row matching the standby

SELECT * FROM pg_stat_replication;
-- may still show streaming WHILE connected
-- but nothing protects WAL if the standby disconnects
```

Healthy streaming **without** a slot looks fine - until the `standby` falls behind or disconnects. Then the `primary` is 
free to recycle WAL after checkpoints.

### Why "it worked until it didn't"

```
With continuous connection + light write load:
  → often fine even without a slot (standby never falls behind recycling)

With burst writes, network blip, or standby restart:
  → primary checkpoints, recycles WAL
  → standby asks for old segment → "already been removed"
```

### Recovery / prevention

1. Create a physical slot on the `primary`:
   ```sql
   SELECT pg_create_physical_replication_slot('standby1_slot');
   ```
2. Point the `standby` at it:
   ```
   primary_slot_name = 'standby1_slot'
   ```
3. Reload/restart the `standby` so WAL Receiver uses the slot
4. If WAL was already removed → rebuild first, then attach the slot so it does not happen again

👉 **A missing slot is a latent failure** - streaming works until the first serious lag or disconnect.

---

## 5. `wal_keep_size` Too Small

`wal_keep_size` is a **soft** minimum amount of WAL the `primary` tries to keep for `standbys` **without** relying on 
slots:

```
# postgresql.conf on primary
wal_keep_size = 128MB    # example - often too small under load
```

### How it relates to slots

| Mechanism            | Retention rule                            | Survives disconnect?        |
|----------------------|-------------------------------------------|-----------------------------|
| **Replication slot** | Keep WAL until **this** consumer confirms | Yes (until cap / disk)      |
| **`wal_keep_size`**  | Keep roughly this many MB of recent WAL   | Only if disconnect is short |

`wal_keep_size` alone is **weaker** than a slot: under a write burst, the `primary` can still generate and recycle past 
what a lagging `standby` needs once that soft floor is exceeded by newer WAL pressure (in practice, slots are the 
reliable fix; `wal_keep_size` is a secondary safety net).

### What you see

Same end state as WAL Removed:

```
ERROR:  requested WAL segment ... has already been removed
```

Especially after:

- Heavy write load that rotated many segments quickly
- `standby` briefly offline
- No slot (or slot not in use)

### Recovery / prevention

1. Prefer a **replication slot** for each `standby` (`primary` fix)
2. If you also use `wal_keep_size`, size it for your worst-case lag window:
   ```
   wal_keep_size = 1GB   # example - match write rate × max acceptable downtime
   ```
3. If the `standby` already hit "WAL removed" → rebuild

```
Write rate 100 MB/min, standby may be offline 20 min:
  need ≥ 2GB retention (plus headroom)
  → slot is safer than guessing wal_keep_size
```

👉 **`wal_keep_size` is a cushion, not a contract. Slots are the contract.** Too-small `wal_keep_size` without a slot 
is a common cause of "it broke after a short outage."

---

## 6. Rebuild Using `pg_basebackup`

When the `standby` cannot catch up (WAL gap, invalidated slot, corrupt `PGDATA`), wipe and re-seed.

### When rebuild is required

| Symptom                                              | Rebuild?    |
|------------------------------------------------------|-------------|
| `requested WAL segment ... has already been removed` | **Yes**     |
| Slot `wal_status = lost` / invalidated               | **Yes**     |
| `standby` data directory corrupted / PVC lost        | **Yes**     |
| Brief network blip, slot intact, lag catching up     | No - wait   |
| `standby` restarted, PVC intact, reconnects          | No - resume |

### Rebuild steps

```
1. Stop the standby Postgres process (if still running)

2. Wipe the old data directory (keep the PVC mount point, empty the contents)
   # WARNING: destroys the old standby copy
   rm -rf $PGDATA/*

3. Re-seed from the primary
   pg_basebackup \
     -h <primary-host> \
     -U repl \
     -D $PGDATA \
     -R \
     -X stream \
     -P

4. Ensure a replication slot exists and is referenced
   # on primary (if missing):
   SELECT pg_create_physical_replication_slot('standby1_slot');
   # on standby (postgresql.auto.conf / -R may need primary_slot_name added):
   primary_slot_name = 'standby1_slot'

5. Start Postgres on the standby

6. Verify
   # primary:
   SELECT state, replay_lsn FROM pg_stat_replication;   -- streaming
   # standby:
   SELECT pg_is_in_recovery();                          -- t
```

### Kubernetes / project shape

The idempotent initContainer pattern:

```
if pgdata empty:     pg_basebackup ...   # first boot OR after intentional wipe
else:                skip                # normal pod restart
```

A rebuild means **intentionally emptying** the PVC data so the initContainer runs `pg_basebackup` again - do not 
confuse that with a normal restart.

👉 **Rebuild = delete `standby` PGDATA + `pg_basebackup` again + (re)attach a slot.** Same tool as first seeding 
([7_Base_Backup.md](./7_Base_Backup.md)).

---

## Failure Decision Tree

```
Standby not streaming?
        │
        ├─ Can it reach primary? (network / DNS / pg_hba / password)
        │     NO  → fix network partition → wait for reconnect
        │     YES ↓
        │
        ├─ Is standby process up?
        │     NO  → start it; if slot exists, catch up
        │     YES ↓
        │
        ├─ Logs say "WAL segment ... has already been removed"
        │   OR slot invalidated?
        │     YES → REBUILD with pg_basebackup
        │     NO  ↓
        │
        └─ Slot missing / not configured?
              YES → create slot + set primary_slot_name
                    (rebuild first if WAL already gone)
              NO  → check lag, disk, max_wal_senders, logs
```

---

## Quick Diagnosis Cheat Sheet

| Symptom                                                        | Likely cause                              | First action                                    |
|----------------------------------------------------------------|-------------------------------------------|-------------------------------------------------|
| `pg_stat_replication` empty, `standby` logs connection errors  | Network partition                         | Fix network / `primary_conninfo` / `pg_hba`     |
| `standby` pod CrashLoop / stopped; `primary` slot `active = f` | `standby` offline                         | Restart `standby`; watch disk if slot holds WAL |
| `requested WAL segment has already been removed`               | WAL removed                               | Rebuild                                         |
| Streaming works, then breaks after outage / write burst        | Missing slot or `wal_keep_size` too small | Add slot; rebuild if gap exists                 |
| Slot `wal_status = lost`                                       | `max_slot_wal_keep_size` hit              | Rebuild; raise cap or fix why `standby` lagged  |

---

## Summary

👉 **Network partition** - connection drops; `primary` keeps writing; catch-up depends on whether WAL was retained.

👉 **`standby` offline** - same retention question; with a slot the `primary` waits (and may fill disk); without a slot, 
long downtime often means rebuild.

👉 **WAL removed** - hard failure; only recovery is `pg_basebackup`.

👉 **Missing replication slot** - latent risk; fine until lag/disconnect, then recycling breaks the `standby`.

👉 **`wal_keep_size` too small** - soft cushion fails under load/outage; prefer slots as the real contract.

👉 **Rebuild** - wipe `standby` `PGDATA`, run `pg_basebackup -R -X stream`, attach a slot, verify `streaming`.

---

## References

- [2_WAL.md](./2_WAL.md) - WAL recycling
- [6_Replication_Slots.md](./6_Replication_Slots.md) - slots, disk full, `max_slot_wal_keep_size`
- [7_Base_Backup.md](./7_Base_Backup.md) - `pg_basebackup` re-seed
- [4_LSN.md](./4_LSN.md) - measuring lag after reconnect
- [9_Promotion.md](./9_Promotion.md) - failover when the `primary` is the one that fails
- [PostgreSQL Documentation - Streaming Replication](https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION)
- [PostgreSQL Documentation - WAL Configuration](https://www.postgresql.org/docs/current/runtime-config-wal.html)
