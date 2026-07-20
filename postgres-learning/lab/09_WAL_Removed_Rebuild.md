# Lab 09 — WAL Removed → Rebuild with `pg_basebackup`

**Goal:** Practice the universal fix when the `standby` can no longer catch up: wipe + re-seed + restart.

**Theory:** [7_Base_Backup.md](../notes/7_Base_Backup.md), [10_Replication_Failure_Scenarios.md](../notes/10_Replication_Failure_Scenarios.md)

**Prerequisite:** Lab 00 knowledge. Use when logs show WAL segment removed, or after Lab 07 optional break.

---

## When you need this

Symptoms:

- Standby log: `requested WAL segment ... has already been removed`
- Slot `wal_status = lost` / invalidated
- Streaming never returns after long outage

---

## Steps

### 1. Confirm broken state (if applicable)

```bash
docker logs standby-db --tail 100
docker exec -it primary-db \
  psql -U prPostgres -d testDB \
  -c "SELECT slot_name, active, wal_status, restart_lsn FROM pg_replication_slots;"
```

| Observation | Value |
|-------------|-------|
| Error / wal_status | |

### 2. Stop standby and wipe its data

```bash
cd postgres-learning
docker compose --profile standby stop standby-db
rm -rf ./data/standby/*
mkdir -p ./data/standby
```

### 3. Ensure slot exists on primary

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT slot_name FROM pg_replication_slots;
-- if missing:
-- SELECT pg_create_physical_replication_slot('standby1_slot');
SQL
```

### 4. Re-seed

```bash
docker run --rm \
  --network pg-net \
  -e PGPASSWORD='qwe123123' \
  -v "$(pwd)/data/standby:/var/lib/postgresql" \
  postgres:18 \
  bash -c '
    set -e
    mkdir -p /var/lib/postgresql/18/docker
    pg_basebackup \
      -h primary-db -p 5432 -U repl \
      -D /var/lib/postgresql/18/docker \
      -R -X stream -P -S standby1_slot
  '

test -f ./data/standby/18/docker/standby.signal && echo OK
```

| Check | Result |
|-------|--------|
| `standby.signal` | |
| `primary_conninfo` present | |

### 5. Start and verify

```bash
docker compose --profile standby up -d standby-db
sleep 3

docker exec -it primary-db \
  psql -U prPostgres -d testDB \
  -c "SELECT state, sync_state FROM pg_stat_replication;"

docker exec -it standby-db \
  psql -U prPostgres -d testDB \
  -c "SELECT pg_is_in_recovery(); SELECT count(*) FROM events;"
```

| Check | Expected | Yours |
|-------|----------|-------|
| streaming | yes | |
| recovery | `t` | |
| data visible | matches primary tables | |

### 6. Decision tree (fill)

| Situation | Action |
|-----------|--------|
| Lag high but streaming | Wait / investigate load — **no** rebuild |
| WAL removed / slot lost | **Rebuild** (this lab) |
| Wrong `primary_conninfo` | Fix config / re-seed with `-R` |
| Accidental second primary (no `standby.signal`) | Re-seed with `-R` |

---

## Expected outcome

- [ ] Fresh clone boots as standby
- [ ] Streaming restored
- [ ] You can recite when rebuild is the only option

---

## Takeaway

> Once needed WAL is gone, no restart closes the gap — only a new base backup can.



Next: [10_Sync_vs_Async_Commit.md](./10_Sync_vs_Async_Commit.md)
