# Lab 08 — Network Partition Simulation

**Goal:** Simulate loss of connectivity between `primary` and `standby`, watch stats, then restore and catch up.

**Theory:** [10_Replication_Failure_Scenarios.md](../notes/10_Replication_Failure_Scenarios.md)

**Prerequisite:** Lab 00 with healthy streaming + slot

---

## Steps

### 1. Baseline

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB \
  -c "SELECT application_name, client_addr, state,
             pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
      FROM pg_stat_replication;"
```

| Baseline  | Value       |
|-----------|-------------|
| state     | `streaming` |
| lag_bytes |             |

### 2. Partition: disconnect standby from the Docker network

```bash
docker network disconnect pg-net standby-db
```

Confirm primary no longer sees a healthy streaming client (may take a moment):

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB \
  -c "SELECT * FROM pg_stat_replication;"
```

| During partition | Value |
|------------------|-------|
| Rows in `pg_stat_replication` | (expect empty or not streaming) |
| Slot still exists? (`pg_replication_slots`) | |

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB \
  -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"
```

### 3. Writes continue on primary (standby cannot receive)

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
CREATE TABLE IF NOT EXISTS lab08_partition (id serial PRIMARY KEY, tag text);
INSERT INTO lab08_partition (tag)
SELECT 'partition-' || g FROM generate_series(1, 200) AS g;
SELECT count(*), pg_current_wal_lsn() FROM lab08_partition;
SQL
```

| During partition | Value |
|------------------|-------|
| Primary row count | |
| Can you query standby? | (may hang / fail — note what happens) |

### 4. Heal the partition

```bash
docker network connect pg-net standby-db
sleep 2

docker exec -it primary-db \
  psql -U prPostgres -d testDB \
  -c "SELECT state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
      FROM pg_stat_replication;"

docker exec -it standby-db \
  psql -U prPostgres -d testDB -c "SELECT count(*) FROM lab08_partition;"
```

| After heal | Value | Expected |
|------------|-------|----------|
| state | | `streaming` |
| lag collapses? | | yes |
| standby count | | matches primary |

### 5. Oral questions

| Question | Your answer |
|----------|-------------|
| Did the primary stop accepting writes during partition? | |
| What retained WAL so the standby could catch up? | |
| What if partition lasted until WAL was recycled with **no** slot? | |

---

## Expected outcome

- [ ] `pg_stat_replication` empties (or drops streaming) during disconnect
- [ ] Slot remains; after reconnect, catch-up succeeds
- [ ] Can contrast this with Lab 07 no-slot failure

---

## Cleanup

If reconnect failed, restart standby:

```bash
docker compose --profile standby restart standby-db
```

---

## Takeaway

> A network partition pauses the **stream**, not necessarily the **primary**. Catch-up needs retained WAL (slot).



Next: [09_WAL_Removed_Rebuild.md](./09_WAL_Removed_Rebuild.md)
