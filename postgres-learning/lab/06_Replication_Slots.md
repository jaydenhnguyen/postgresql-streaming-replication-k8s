# Lab 06 — Replication Slots Deep Dive

**Goal:** Inspect slot metadata, watch `restart_lsn` move, and state the disk-full risk out loud.

**Theory:** [6_Replication_Slots.md](../notes/6_Replication_Slots.md)

**Prerequisite:** Lab 00 (`standby1_slot` exists)

---

## Steps

### 1. Inspect the slot

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT slot_name, slot_type, active, restart_lsn, confirmed_flush_lsn,
       wal_status, safe_wal_size
FROM pg_replication_slots;

SHOW max_replication_slots;
SHOW max_slot_wal_keep_size;
SQL
```

| Field | Value |
|-------|-------|
| `slot_name` | |
| `active` | (expect `t` if standby up) |
| `restart_lsn` | |
| `wal_status` | |
| `max_replication_slots` | |
| `max_slot_wal_keep_size` | (`-1` = unlimited) |

### 2. Slot files on disk

```bash
docker exec -it primary-db bash -c '
PGDATA="$(psql -U prPostgres -d testDB -Atc "SHOW data_directory")"
ls -la "$PGDATA/pg_replslot"
ls -la "$PGDATA/pg_replslot/standby1_slot"
'
```

| Observation | Note |
|-------------|------|
| Directory under `pg_replslot/` | |

### 3. Watch `restart_lsn` advance

Record current `restart_lsn`, write load, check again:

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT restart_lsn FROM pg_replication_slots WHERE slot_name = 'standby1_slot';

CREATE TABLE IF NOT EXISTS lab06_slot (id bigserial, x text);
INSERT INTO lab06_slot (x) SELECT 's' FROM generate_series(1, 10000);

SELECT restart_lsn FROM pg_replication_slots WHERE slot_name = 'standby1_slot';
SQL
```

| When | `restart_lsn` |
|------|---------------|
| Before load | |
| After standby caught up | |

### 4. Checkpoint vs slot (fill from understanding)

| | Checkpoint | Slot |
|-|------------|------|
| Protects | | |
| Asks | "Is my `base/` caught up?" | "Has consumer consumed WAL?" |
| Created by | automatic | admin / `pg_basebackup -S` |

### 5. Risk statement

| Scenario | What happens to WAL / disk? |
|----------|-----------------------------|
| Standby offline **with** slot | |
| Standby offline **forever**, unlimited `max_slot_wal_keep_size` | |

---

## Expected outcome

- [ ] Can read `pg_replication_slots` and explain `restart_lsn`
- [ ] Know `max_replication_slots` = how many slots, not how much WAL
- [ ] Can explain disk-full risk of an abandoned slot

---

## Takeaway

> A slot is a **contract**: do not recycle WAL past this consumer's position. Powerful — and dangerous if the consumer never returns.



Next: [07_Slot_vs_No_Slot_Failure.md](./07_Slot_vs_No_Slot_Failure.md)
