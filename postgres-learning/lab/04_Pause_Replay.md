# Lab 04 — Pause Replay (Receive vs Replay)

**Goal:** Force a visible gap between WAL **received** and WAL **replayed**, then resume and catch up.

**Theory:** [4_LSN.md](../notes/4_LSN.md), [8_Standby_Initialization.md](../notes/8_Standby_Initialization.md)

**Prerequisite:** Labs 00, 03

---

## Steps

### 1. Pause replay on the `standby`

```bash
docker exec -it standby-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_is_wal_replay_paused();
SELECT pg_wal_replay_pause();
SELECT pg_is_wal_replay_paused();
SQL
```

| Check | Value |
|-------|-------|
| Paused? | must be `t` |

### 2. Write on the `primary` while paused

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
CREATE TABLE IF NOT EXISTS lab04_pause (
  id serial PRIMARY KEY,
  tag text
);
TRUNCATE lab04_pause;
INSERT INTO lab04_pause (tag)
SELECT 'paused-' || g FROM generate_series(1, 500) AS g;
SELECT count(*) FROM lab04_pause;
SELECT pg_current_wal_lsn();
SQL
```

### 3. Compare receive vs replay on `standby`

```bash
docker exec -it standby-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_last_wal_receive_lsn() AS receive;
SELECT pg_last_wal_replay_lsn()  AS replay;
SELECT pg_wal_lsn_diff(
         pg_last_wal_receive_lsn(),
         pg_last_wal_replay_lsn()
       ) AS stuck_replay_bytes;
SELECT count(*) FROM lab04_pause;  -- may error or show old count while paused
SQL
```

| Metric | Value |
|--------|-------|
| receive LSN | |
| replay LSN | |
| `stuck_replay_bytes` | (should be **> 0**) |
| Visible row count on standby | |

**What this proves:** WAL can still **arrive** (receive moves) while **apply** is frozen (replay stuck).

### 4. Resume and verify catch-up

```bash
docker exec -it standby-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_wal_replay_resume();
SELECT pg_is_wal_replay_paused();
SELECT pg_wal_lsn_diff(
         pg_last_wal_receive_lsn(),
         pg_last_wal_replay_lsn()
       ) AS gap_after_resume;
SELECT count(*) FROM lab04_pause;
SQL
```

| After resume | Value | Expected |
|--------------|-------|----------|
| Paused? | | `f` |
| Gap bytes | | near `0` |
| `count(*)` | | `500` |

### 5. Primary view during pause (optional)

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB \
  -c "SELECT state, sent_lsn, flush_lsn, replay_lsn,
             pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
      FROM pg_stat_replication;"
```

| Observation | Your note |
|-------------|-----------|
| Did `replay_lsn` lag behind `flush_lsn` while paused? | |

---

## Expected outcome

- [ ] While paused: receive ahead of replay
- [ ] Standby missing/new rows until resume
- [ ] After resume: counts match, gap collapses

---

## Cleanup

```bash
docker exec -it standby-db \
  psql -U prPostgres -d testDB -c "SELECT pg_wal_replay_resume();"
```

Always leave replay **unpaused** before other labs.

---

## Takeaway

> **Receive ≠ replay.** Promotion safety depends on **replay** position — that is the data the standby has actually applied.



Next: [05_Checkpoints_and_Recycling.md](./05_Checkpoints_and_Recycling.md)
