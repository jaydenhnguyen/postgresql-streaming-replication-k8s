# Lab 02 - Commit Flow and WAL

**Goal:** Watch WAL grow on commit and prove durability is WAL-first, not `base/`-first.

**Theory:** [3_Commit_Flow.md](../notes/3_Commit_Flow.md), [2_WAL.md](../notes/2_WAL.md)

**Prerequisite:** Lab 00

---

## Steps

### 1. Snapshot LSN and WAL file before write

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_current_wal_lsn() AS lsn_before;
SELECT pg_walfile_name(pg_current_wal_lsn()) AS wal_file_before;
SQL
```

| Field | Value |
|-------|-------|
| `lsn_before` | |
| `wal_file_before` | |

### 2. Commit a batch of inserts

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
CREATE TABLE IF NOT EXISTS lab02_commits (
  id serial PRIMARY KEY,
  note text,
  created_at timestamptz DEFAULT now()
);

INSERT INTO lab02_commits (note)
SELECT 'commit-flow-' || g FROM generate_series(1, 1000) AS g;

SELECT pg_current_wal_lsn() AS lsn_after;
SELECT pg_walfile_name(pg_current_wal_lsn()) AS wal_file_after;
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0'); -- rough absolute; better use before/after below
SQL
```

Re-run with your saved `lsn_before` plugged in:

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB \
  -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '<PASTE_lsn_before>') AS bytes_written;"
```

| Field | Value |
|-------|-------|
| `lsn_after` | |
| Bytes advanced | |
| Same WAL segment file? (yes/no) | |

### 3. Peek at `pg_wal/` size/growth

```bash
docker exec -it primary-db bash -c '
PGDATA="$(psql -U prPostgres -d testDB -Atc "SHOW data_directory")"
ls -lh "$PGDATA/pg_wal" | head -20
du -sh "$PGDATA/pg_wal"
'
```

| Observation | Value |
|-------------|-------|
| Approximate `pg_wal` size | |
| Segment file size you see | (expect ~16 MB) |

### 4. Prove standby got the same rows (WAL shipped, not file copy)

```bash
docker exec -it standby-db \
  psql -U prPostgres -d testDB -c "SELECT count(*) FROM lab02_commits;"
```

| Side | count |
|------|-------|
| Primary | |
| Standby | |

### 5. Mental model check (no command)

Answer without looking at notes:

| Question | Your answer |
|----------|-------------|
| When does the client get `COMMIT` OK - after WAL fsync or after `base/` flush? | |
| What is a dirty page? | |
| What does a checkpoint do to dirty pages? | |

---

## Expected outcome

- [ ] LSN advanced after the insert batch
- [ ] Standby row count matches primary
- [ ] You can state the write-ahead rule in one sentence

---

## Takeaway

> Streaming ships **WAL**, not copies of `base/` files. The standby rebuilds its own `base/` by replaying WAL.



Next: [03_LSN_Lag_Measurement.md](./03_LSN_Lag_Measurement.md)
