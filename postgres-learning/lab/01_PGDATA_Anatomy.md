# Lab 01 — PGDATA Anatomy Tour

**Goal:** Map the live cluster on disk and name the processes that make replication work.

**Theory:** [1_PostgreSQL_Architecture.md](../notes/1_PostgreSQL_Architecture.md)

**Prerequisite:** Lab 00 done (both containers up)

---

## Steps

### 1. Find `data_directory` on both

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB -c "SHOW data_directory;"

docker exec -it standby-db \
  psql -U prPostgres -d testDB -c "SHOW data_directory;"
```

| Side | Path you saw |
|------|----------------|
| Primary | |
| Standby | |

### 2. Tour key directories (primary)

```bash
docker exec -it primary-db bash -c '
PGDATA="$(psql -U prPostgres -d testDB -Atc "SHOW data_directory")"
echo "=== top ===" && ls "$PGDATA"
echo "=== base (DBs) ===" && ls "$PGDATA/base"
echo "=== pg_wal (sample) ===" && ls "$PGDATA/pg_wal" | head
echo "=== slots ===" && ls -la "$PGDATA/pg_replslot" 2>/dev/null || true
'
```

| Path | What lives there (your note) |
|------|------------------------------|
| `base/` | |
| `global/` | |
| `pg_wal/` | |
| `pg_replslot/` | |
| `postgresql.conf` / `postgresql.auto.conf` | |
| `pg_hba.conf` | |

### 3. Identity files: primary vs standby

```bash
# on host
ls ./data/primary/18/docker/standby.signal 2>&1
ls ./data/standby/18/docker/standby.signal 2>&1
grep -E 'primary_conninfo|primary_slot_name' ./data/standby/18/docker/postgresql.auto.conf
```

| Check | Primary | Standby |
|-------|---------|---------|
| `standby.signal` exists? | | |
| `primary_conninfo` present? | | |

### 4. Server processes

```bash
docker exec -it primary-db bash -c 'ps aux | grep -E "postgres|wal|check|sender" | grep -v grep'
docker exec -it standby-db  bash -c 'ps aux | grep -E "postgres|wal|check|receiver|startup" | grep -v grep'
```

| Process | Seen on primary? | Seen on standby? | Job in one phrase |
|---------|------------------|------------------|-------------------|
| WAL Writer | | | |
| Checkpointer | | | |
| WAL Sender | | | |
| WAL Receiver | | | |
| Startup | | | |

### 5. Auth path for replication

```bash
docker exec -it primary-db bash -c '
PGDATA="$(psql -U prPostgres -d testDB -Atc "SHOW data_directory")"
grep -n replication "$PGDATA/pg_hba.conf"
'
```

| Observation | Your answer |
|-------------|-------------|
| Why does the DATABASE column say `replication` (not `all`)? | |

### 6. Cluster vs database

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT oid, datname FROM pg_database ORDER BY oid;
SELECT pg_current_wal_lsn();  -- one stream for whole cluster
SQL
```

| Observation | Your answer |
|-------------|-------------|
| How many DBs in this cluster? | |
| Is WAL per-database or cluster-wide? | |

---

## Expected outcome

- [ ] Can point at `base/`, `pg_wal/`, `pg_replslot/` and say what each is for
- [ ] Know which side has `standby.signal`
- [ ] Can name WAL Sender (primary) vs WAL Receiver (standby)

---

## Takeaway

> _One sentence:_ What makes a cloned data directory a `standby` instead of a second `primary`?



Next: [02_Commit_Flow_and_WAL.md](./02_Commit_Flow_and_WAL.md)
