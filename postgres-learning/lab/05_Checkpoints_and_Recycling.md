# Lab 05 — Checkpoints and WAL Recycling

**Goal:** See what triggers a checkpoint, distinguish `checkpoint_timeout` vs `max_wal_size`, and contrast that with `wal_keep_size`.

**Theory:** [5_Checkpoint.md](../notes/5_Checkpoint.md), [2_WAL.md](../notes/2_WAL.md) (`max_wal_size` vs `wal_keep_size`)

**Prerequisite:** Lab 00

---

## Steps

### 1. Read current settings and stats

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SHOW checkpoint_timeout;
SHOW max_wal_size;
SHOW min_wal_size;
SHOW wal_keep_size;

SELECT checkpoints_timed, checkpoints_req,
       buffers_checkpoint, buffers_clean
FROM pg_stat_bgwriter;
SQL
```

| Setting / stat | Value |
|----------------|-------|
| `checkpoint_timeout` | |
| `max_wal_size` | |
| `wal_keep_size` | |
| `checkpoints_timed` | |
| `checkpoints_req` | |

### 2. Force a checkpoint and watch LSN / control

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_current_wal_lsn() AS before_ckpt;
CHECKPOINT;
SELECT pg_current_wal_lsn() AS after_ckpt;
SELECT * FROM pg_control_checkpoint();
SQL
```

| Observation | Value |
|-------------|-------|
| Did LSN move around `CHECKPOINT`? | |
| Checkpoint LSN / redo location (from control) | |

### 3. Timed vs requested (conceptual fill-in)

| Trigger | Controlled by | When it wins |
|---------|---------------|--------------|
| Time | `checkpoint_timeout` | Quiet / moderate load |
| Size | `max_wal_size` | Busy write load (early checkpoint) |

In your words:

| Question | Answer |
|----------|--------|
| Does `checkpoint_timeout = 5min` mean each dirty page waits exactly 5 minutes? | |
| Does raising `max_wal_size` protect a lagging standby? | |

### 4. List WAL segments before/after activity

```bash
docker exec -it primary-db bash -c '
PGDATA="$(psql -U prPostgres -d testDB -Atc "SHOW data_directory")"
echo "WAL files:" && ls "$PGDATA/pg_wal" | head
'
```

Generate some WAL, checkpoint, look again:

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
CREATE TABLE IF NOT EXISTS lab05_wal (id bigserial, b text);
INSERT INTO lab05_wal (b) SELECT repeat('w', 100) FROM generate_series(1, 20000);
CHECKPOINT;
SQL
```

| Observation | Note |
|-------------|------|
| Segment names / count change? | |
| Recycle = delete forever? (yes/no) | (expect **no** — rename/reuse) |

### 5. Three retention decisions (from notes)

Fill:

| Mechanism | Protects | Soft or hard? |
|-----------|----------|---------------|
| Checkpoint cut point | Local crash recovery | |
| `wal_keep_size` | Standbys without slot | |
| Replication slot | Named consumer | |

---

## Expected outcome

- [ ] Can explain timeout vs `max_wal_size` OR-trigger
- [ ] Can say why `max_wal_size ≠ wal_keep_size`
- [ ] Know recycle means rename/reuse, not "forget forever if a slot needs it"

---

## Takeaway

> Checkpoint answers "is **my** `base/` caught up?" A slot answers "has **my standby** consumed this WAL yet?"



Next: [06_Replication_Slots.md](./06_Replication_Slots.md)
