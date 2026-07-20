# Lab 00 — Bootstrap Primary + Standby

**Goal:** From a clean machine, bring up a streaming pair: writable `primary`, read-only `standby`, proven replication.

**Theory:** [7_Base_Backup.md](../notes/7_Base_Backup.md), [8_Standby_Initialization.md](../notes/8_Standby_Initialization.md), deep walkthrough [0_Bootstrap_Primary_Standby.md](../notes/0_Bootstrap_Primary_Standby.md)

**Time:** ~20–30 min

---

## Prerequisites

```bash
cd postgres-learning
docker --version && docker compose version
```

---

## Steps

### 0. Clean slate (recommended)

```bash
docker compose --profile standby down
rm -rf ./data/primary ./data/standby
mkdir -p ./data/primary ./data/standby
```

### 1. Start `primary` only

```bash
docker compose up -d primary-db
docker logs primary-db --tail 30

docker exec -it primary-db \
  psql -U prPostgres -d testDB -c "SELECT version(); SELECT pg_is_in_recovery();"
```

| Observation | Your value | Expected |
|-------------|------------|----------|
| `pg_is_in_recovery()` | | `f` |
| Version string contains | | `PostgreSQL 18` |

### 2. Configure replication on `primary`

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
ALTER SYSTEM SET wal_level = replica;
ALTER SYSTEM SET max_wal_senders = 10;
ALTER SYSTEM SET max_replication_slots = 5;
ALTER SYSTEM SET wal_keep_size = '256MB';
ALTER SYSTEM SET listen_addresses = '*';
CREATE ROLE repl WITH REPLICATION LOGIN PASSWORD 'qwe123123';
SQL
```

```bash
docker exec -it primary-db bash -c '
PGDATA="$(psql -U prPostgres -d testDB -Atc "SHOW data_directory")"
grep -q "host replication repl" "$PGDATA/pg_hba.conf" || \
  echo "host replication repl 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
grep -q "host all all all" "$PGDATA/pg_hba.conf" || \
  echo "host all all all scram-sha-256" >> "$PGDATA/pg_hba.conf"
'

docker compose restart primary-db
```

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SHOW wal_level;
SHOW max_wal_senders;
SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'repl';
SQL
```

| Observation | Your value | Expected |
|-------------|------------|----------|
| `wal_level` | | `replica` |
| `rolreplication` for `repl` | | `t` |

### 3. Create physical slot

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_create_physical_replication_slot('standby1_slot');
SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;
SQL
```

| Observation | Your value | Expected |
|-------------|------------|----------|
| Slot exists | | `standby1_slot`, `physical` |
| `active` before standby starts | | `f` |

### 4. Seed `standby` with `pg_basebackup`

```bash
docker compose --profile standby stop standby-db 2>/dev/null || true
rm -rf ./data/standby/*
mkdir -p ./data/standby

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

test -f ./data/standby/18/docker/standby.signal && echo "standby.signal OK"
grep primary_conninfo ./data/standby/18/docker/postgresql.auto.conf
```

| Observation | Your value | Expected |
|-------------|------------|----------|
| `standby.signal` present? | | yes |
| `primary_conninfo` hosts | | `primary-db`, user `repl` |
| Why `-R` matters (one line) | | |

### 5. Start `standby` and prove read-only

```bash
docker compose --profile standby up -d standby-db
docker logs standby-db --tail 40

docker exec -it standby-db \
  psql -U prPostgres -d testDB -c "SELECT pg_is_in_recovery();"

docker exec -it standby-db \
  psql -U prPostgres -d testDB \
  -c "CREATE TABLE should_fail (id int);"
```

| Observation | Your value | Expected |
|-------------|------------|----------|
| `pg_is_in_recovery()` | | `t` |
| Write error message | | read-only / recovery |

### 6. Prove streaming + data

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT application_name, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;

CREATE TABLE IF NOT EXISTS events (
  id serial PRIMARY KEY,
  tag text NOT NULL,
  created_at timestamptz DEFAULT now()
);
INSERT INTO events (tag)
SELECT 'lab00-' || g FROM generate_series(1, 20) AS g;
SELECT count(*) FROM events;
SQL

docker exec -it standby-db \
  psql -U prPostgres -d testDB -c "SELECT count(*) FROM events;"
```

| Observation | Your value | Expected |
|-------------|------------|----------|
| `pg_stat_replication.state` | | `streaming` |
| Row count primary | | `20` (or more if re-run) |
| Row count standby | | same as primary |

---

## Expected outcome

- [ ] `primary` accepts writes; `standby` rejects writes
- [ ] One streaming row in `pg_stat_replication`
- [ ] Same `events` row count on both sides
- [ ] Slot `standby1_slot` becomes `active = t` after standby connects

---

## Takeaway

> _Write in your words:_ Why must the `standby` data directory stay empty until `pg_basebackup` runs?



---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `pg_basebackup` auth failed | Re-check `repl` role + `pg_hba` + restart |
| Empty `pg_stat_replication` | Standby logs, `standby.signal`, network `pg-net` |
| Port in use | Free `:5432`/`:5433` or change compose ports |

Next: [01_PGDATA_Anatomy.md](./01_PGDATA_Anatomy.md)
