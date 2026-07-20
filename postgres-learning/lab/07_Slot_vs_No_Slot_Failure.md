# Lab 07 — Slot vs No-Slot Failure

**Goal:** Prove why a physical slot (or enough retained WAL) matters when the `standby` is offline under write load.

**Theory:** [6_Replication_Slots.md](../notes/6_Replication_Slots.md), [10_Replication_Failure_Scenarios.md](../notes/10_Replication_Failure_Scenarios.md)

**Prerequisite:** Lab 00. **Warning:** this lab can break replication on purpose. Lab 09 rebuilds if needed.

---

## Part A — With a slot (safe offline)

### A1. Confirm slot in use

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB \
  -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"
```

### A2. Stop standby, generate WAL, restart standby

```bash
docker compose --profile standby stop standby-db

docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
CREATE TABLE IF NOT EXISTS lab07_safe (id bigserial, b text);
INSERT INTO lab07_safe (b) SELECT repeat('a', 50) FROM generate_series(1, 30000);
CHECKPOINT;
SELECT slot_name, active, restart_lsn, wal_status FROM pg_replication_slots;
SQL

docker compose --profile standby up -d standby-db
sleep 3

docker exec -it primary-db \
  psql -U prPostgres -d testDB \
  -c "SELECT state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag
      FROM pg_stat_replication;"

docker exec -it standby-db \
  psql -U prPostgres -d testDB -c "SELECT count(*) FROM lab07_safe;"
```

| Observation (WITH slot) | Value |
|-------------------------|-------|
| Slot `active` while standby stopped | `f` (slot still exists) |
| After restart: streaming again? | |
| Row count matches? | |

---

## Part B — Without a slot (can break)

Only do this if you are ready to rebuild (Lab 09). Use a **temporary** second approach: drop the slot **while standby is stopped**, generate enough WAL that recycling can remove needed segments, then start standby.

> Lab-scale caveat: with default small load, WAL may still be present. To force failure you need enough WAL past checkpoint + no retention. Prefer understanding the **mechanism** even if you skip forcing a hard break.

### B1. Conceptual drill (required even if you skip force-break)

| Condition | Likely result when standby returns |
|-----------|-------------------------------------|
| Offline + **slot** holds `restart_lsn` | Catch-up from retained WAL |
| Offline + **no slot** + small `wal_keep_size` + heavy writes + checkpoints | `requested WAL segment has already been removed` → rebuild |
| Offline + no slot + short outage + little write | May still catch up by luck |

### B2. Optional force (advanced)

```bash
# STOP standby first
docker compose --profile standby stop standby-db

docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_drop_replication_slot('standby1_slot');
ALTER SYSTEM SET wal_keep_size = '0';
SELECT pg_reload_conf();
SQL

# Generate a lot of WAL + checkpoints (may take a bit / disk)
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
CREATE TABLE IF NOT EXISTS lab07_break (id bigserial, b text);
INSERT INTO lab07_break (b) SELECT repeat('z', 200) FROM generate_series(1, 200000);
CHECKPOINT;
INSERT INTO lab07_break (b) SELECT repeat('z', 200) FROM generate_series(1, 200000);
CHECKPOINT;
SQL

docker compose --profile standby up -d standby-db
docker logs standby-db --tail 80
```

| Observation (NO slot) | Value |
|-----------------------|-------|
| Error in standby logs? | |
| Streaming restored without rebuild? | |

If broken → go to [09_WAL_Removed_Rebuild.md](./09_WAL_Removed_Rebuild.md).

### B3. Restore lab settings after optional break attempt

If you only dropped the slot but replication still works, recreate slot from standby using `primary_slot_name` / re-seed, or:

```bash
# Prefer Lab 09 full re-seed for a clean state
```

Also restore `wal_keep_size` if you changed it:

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
ALTER SYSTEM SET wal_keep_size = '256MB';
SELECT pg_reload_conf();
SQL
```

---

## Expected outcome

- [ ] Part A: standby returns cleanly with slot
- [ ] Can explain why no-slot + long outage + writes → rebuild
- [ ] Know the error string to watch for in logs

---

## Takeaway

> **`wal_keep_size` is a cushion. A slot is the contract.** Without a contract, recycled WAL is gone forever.



Next: [08_Network_Partition.md](./08_Network_Partition.md)
