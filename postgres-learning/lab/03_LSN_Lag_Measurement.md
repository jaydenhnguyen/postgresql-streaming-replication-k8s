# Lab 03 - LSN Lag Measurement

**Goal:** Measure replication lag in bytes with the three LSN functions and `pg_stat_replication`.

**Theory:** [4_LSN.md](../notes/4_LSN.md)

**Prerequisite:** Lab 00

---

## Steps

### 1. Idle baseline (both sides)

**Primary:**

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_current_wal_lsn() AS primary_lsn;
SELECT application_name, state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
SQL
```

**Standby:**

```bash
docker exec -it standby-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_is_in_recovery();
SELECT pg_last_wal_receive_lsn() AS receive_lsn;
SELECT pg_last_wal_replay_lsn()  AS replay_lsn;
SELECT pg_wal_lsn_diff(
         pg_last_wal_receive_lsn(),
         pg_last_wal_replay_lsn()
       ) AS receive_minus_replay_bytes;
SQL
```

| Metric (idle) | Value |
|---------------|-------|
| Primary `pg_current_wal_lsn` | |
| Standby receive LSN | |
| Standby replay LSN | |
| Lag bytes (`primary` → `replay_lsn`) | |
| Non-zero when idle? (yes/no + why) | |

### 2. Write burst - watch lag move

Terminal A (load):

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
CREATE TABLE IF NOT EXISTS lab03_load (
  id bigserial PRIMARY KEY,
  payload text
);
INSERT INTO lab03_load (payload)
SELECT repeat('x', 200) FROM generate_series(1, 50000);
SQL
```

Terminal B (during/after load), re-run the primary `pg_stat_replication` query.

| Metric (during/after burst) | Value |
|-----------------------------|-------|
| Peak `lag_bytes` you saw | |
| Did lag return near 0 after catch-up? | |

### 3. Map the pipeline

Fill from what you observed:

```
Primary write  →  sent_lsn  →  write_lsn  →  flush_lsn  →  replay_lsn
     │                │            │            │             │
   (you)           (network)    (standby      (standby      (standby
                                 RAM)          disk)         applied)
```

| Stage | Meaning in your words |
|-------|----------------------|
| `sent_lsn` | |
| `write_lsn` | |
| `flush_lsn` | |
| `replay_lsn` | |

### 4. Oral-demo phrase

Practice saying:

> "Lag is `pg_wal_lsn_diff(primary_lsn, standby_replay_lsn)` = _____ bytes under load."

---

## Expected outcome

- [ ] Can run and interpret all three LSN functions
- [ ] Can show lag rising under load and falling after
- [ ] Can explain a small idle gap if present (WAL activity / timing)

---

## Takeaway

> LSN lag is a **byte distance** on the WAL tape, not a row count - but at promotion time that byte gap is exactly the committed work the standby has not replayed.



Next: [04_Pause_Replay.md](./04_Pause_Replay.md)
