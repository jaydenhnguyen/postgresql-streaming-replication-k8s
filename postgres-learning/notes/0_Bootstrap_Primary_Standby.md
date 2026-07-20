# Lab: Bootstrap Primary + Standby (Docker)

Hands-on guide to bring up a streaming replication pair from a clean machine:

1. Launch the `primary`
2. Configure it for replication
3. Seed the `standby` with `pg_basebackup`
4. Start the `standby`
5. Prove replication works

This matches the lab layout under `postgres-learning/` (`docker-compose.yaml`, `postgres:18`).

Related theory: [7_Base_Backup.md](./7_Base_Backup.md), [8_Standby_Initialization.md](./8_Standby_Initialization.md).

---

## What will end with

```
Host
 ├── primary-db   :5432  → write primary
 └── standby-db  :5433  → read-only standby (streaming)

Network: pg-net
Volumes:
  ./data/primary → primary PGDATA
  ./data/standby → standby PGDATA
```

Credentials used in this lab (lab-only, not for production):

| Item                 | Value          |
|----------------------|----------------|
| Superuser            | `prPostgres`   |
| Superuser password   | `p@sswoord123` |
| App DB               | `testDB`       |
| Replication user     | `repl`         |
| Replication password | `qwe123123`    |

---

## Prerequisites

- Docker Desktop (or Docker Engine) running
- `docker compose` available
- Enough free disk for two data directories

```bash
cd postgres-learning
docker --version
docker compose version
```

---

## 0. Clean slate (optional but recommended)

**Why:** replication setup is stateful - leftover data directories from previous experiments (an old cluster, a stale 
`standby.signal`, a half-finished basebackup) cause the most confusing failures. Starting from empty directories 
guarantees every step below behaves as described.

If already have half-configured data and want a fresh start:

```bash
cd postgres-learning

# stop containers
docker compose --profile standby down

# wipe data directories (DESTROYS the lab DBs)
rm -rf ./data/primary ./data/standby
mkdir -p ./data/primary ./data/standby
```

👉 Only wipe if are okay losing the current lab data.

---

## 1. Start the `primary` only

**Why:** the `standby` is not an independent server - it starts life as a byte-level clone of the `primary`. So the 
`primary` must exist first, and the `standby`'s data directory must stay **empty** until `pg_basebackup` fills it. If 
the `standby` container started now, the postgres image would run `initdb` and create a brand-new unrelated cluster - 
that cluster could never follow the `primary`'s WAL stream (different system identifier, different history).

📚 Reference: 
- [1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md) - what a cluster/`PGDATA` is
- [7_Base_Backup.md](./7_Base_Backup.md) - why the clone must come from the `primary`.

```bash
cd postgres-learning

# start only primary-db (standby uses profile "standby")
docker compose up -d primary-db

# wait until healthy / accepting connections
docker compose ps
docker logs primary-db --tail 30
```

Confirm can connect:

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB -c "SELECT version();"
```

Expected: a PostgreSQL 18 version string.

Also confirm role:

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB -c "SELECT pg_is_in_recovery();"
```

Expected: `f` (this is the `primary`).

---

## 2. Configure the `primary` for replication

**Why:** out of the box, a `primary` does not stream WAL to anyone. Three things must be true before a `standby` can 
connect:

1. WAL contains **enough information** to rebuild another server (`wal_level = replica`)
2. There are **sender processes** available to stream it (`max_wal_senders`)
3. A role with the **REPLICATION privilege** is allowed to connect through `pg_hba.conf`

### 2.1 Replication settings (`ALTER SYSTEM`)

**What each setting does:**

| Setting                     | Why it is needed                                                                                                                     |
|-----------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| `wal_level = replica`       | WAL now carries enough detail for a `standby` to replay (default is already `replica` on modern versions, set explicitly to be sure) |
| `max_wal_senders = 10`      | Each streaming `standby` **and** each `pg_basebackup` consumes one WAL Sender connection                                             |
| `max_replication_slots = 5` | "Parking spaces" for slots - must be > 0 before section 3 can create one                                                             |
| `wal_keep_size = '256MB'`   | Soft cushion of retained WAL for standbys **without** a slot (the slot is the real contract)                                         |
| `listen_addresses = '*'`    | Accept TCP connections from other containers, not just localhost                                                                     |

📚 Reference: 
- [2_WAL.md](./2_WAL.md) - `wal_level` and the WAL directory,
- [6_Replication_Slots.md](./6_Replication_Slots.md) - `max_replication_slots`, `wal_keep_size` vs slots.

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
ALTER SYSTEM SET wal_level = replica;
ALTER SYSTEM SET max_wal_senders = 10;
ALTER SYSTEM SET max_replication_slots = 5;
ALTER SYSTEM SET wal_keep_size = '256MB';
ALTER SYSTEM SET listen_addresses = '*';
SQL
```

These land in `postgresql.auto.conf` (inside PGDATA).

### 2.2 Create the replication role

**Why:** `pg_basebackup` (and later the `standby`'s WAL Receiver) reads the **raw cluster** - every database, every 
byte - bypassing table-level permissions. That power needs its own privilege flag (`REPLICATION`) and its own 
dedicated role. Least privilege: `repl` can replicate, and nothing else.

📚 Reference: 
- [7_Base_Backup.md](./7_Base_Backup.md) - "Why It Needs a Replication Role".

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
CREATE ROLE repl WITH REPLICATION LOGIN PASSWORD 'qwe123123';
\du
SQL
```

If the role already exists:

```sql
ALTER ROLE repl WITH REPLICATION LOGIN PASSWORD 'qwe123123';
```

### 2.3 Allow replication connections in `pg_hba.conf`

**Why:** having the `repl` role is not enough - `pg_hba.conf` decides **who may connect, from where, and how they 
authenticate**. Replication connections match the special `replication` keyword in the DATABASE column (the `all` 
keyword does **not** cover them), so they need their own line. Without it, `pg_basebackup` fails with 
"no pg_hba.conf entry for replication connection".

📚 Reference: 
- [1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md) - `pg_hba.conf` syntax and the `replication` keyword.

Find the data directory:

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB -Atc "SHOW data_directory;"
```

On `postgres:18` with this compose file, that is usually:

```text
/var/lib/postgresql/18/docker
```

Append a replication rule (and a general host rule if missing):

```bash
docker exec -it primary-db bash -c '
PGDATA="$(psql -U prPostgres -d testDB -Atc "SHOW data_directory")"
grep -q "host replication repl" "$PGDATA/pg_hba.conf" || \
  echo "host replication repl 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
grep -q "host all all all" "$PGDATA/pg_hba.conf" || \
  echo "host all all all scram-sha-256" >> "$PGDATA/pg_hba.conf"
tail -n 5 "$PGDATA/pg_hba.conf"
'
```

### 2.4 Restart the `primary` so settings apply

**Why:** some settings are read only at server startup. `wal_level`, `max_wal_senders`, `max_replication_slots`, and 
`listen_addresses` all need a **restart** - a `pg_reload_conf()` is not enough. (`pg_hba.conf` changes would only 
need a reload, but since we are restarting anyway, both get picked up.)

```bash
docker compose restart primary-db
docker logs primary-db --tail 20
```

Verify:

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SHOW wal_level;
SHOW max_wal_senders;
SHOW max_replication_slots;
SHOW listen_addresses;
SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'repl';
SQL
```

Expected:

| Setting                     | Value     |
|-----------------------------|-----------|
| `wal_level`                 | `replica` |
| `max_wal_senders`           | `10`      |
| `rolreplication` for `repl` | `t`       |

---

## 3. (Recommended) Create a physical replication slot

**Why:** the `primary` recycles old WAL after checkpoints. Without a slot, a `standby` that lags or goes offline can 
come back to find its necessary WAL **gone** - "requested WAL segment has already been removed" - and the only fix is a 
full re-seed. A **physical slot** is the `primary`'s bookmark for this `standby`: "do not recycle WAL past this 
consumer's position." The slot makes the `standby`'s progress binding on the `primary`.

Tradeoff to remember: a slot whose `standby` never comes back pins WAL forever and can fill the `primary`'s disk - 
that is why `max_slot_wal_keep_size` exists.

📚 Reference: 
- [6_Replication_Slots.md](./6_Replication_Slots.md) - slots vs `wal_keep_size`, disk-full risk
- [5_Checkpoint.md](./5_Checkpoint.md) - why checkpoints recycle WAL in the first place.

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_create_physical_replication_slot('standby1_slot');
SELECT slot_name, slot_type, active, restart_lsn
FROM pg_replication_slots;
SQL
```

If it already exists, will get an error - that is fine. List slots to confirm.

---

## 4. Seed the `standby` with `pg_basebackup`

**Why this step exists completely:** streaming replication only ships **WAL** - the diffs. It never ships the actual data 
files. So before a `standby` can follow the stream, it needs a **starting point**: a full byte-level copy of the 
`primary`'s cluster (`base/`, `global/`, config, everything). That is exactly what `pg_basebackup` produces. Think of 
it as: *clone the whole book once, then subscribe to the errata.*

Two things make this clone special compared to a naive `cp -r`:

1. **It is consistent.** The `primary` keeps running (and writing!) during the copy. The copied files are internally 
   torn/inconsistent, but `pg_basebackup` also captures all WAL generated **during** the copy (`-X stream`). On first 
   startup, the `standby` replays that WAL to repair itself into a consistent state - the same mechanism as crash 
   recovery.
2. **It runs only once.** After the clone exists, the `standby` keeps itself up to date via streaming. Re-running 
   `pg_basebackup` is only needed when replication is broken beyond repair (see section 9).

📚 Reference: 
- [7_Base_Backup.md](./7_Base_Backup.md) - full cluster copy, consistency, replication protocol
- [3_Commit_Flow.md](./3_Commit_Flow.md) - why WAL replay can repair torn data files.

### 4.1 Make sure the `standby` is stopped and empty

**Why:** `pg_basebackup` refuses to write into a non-empty directory - and even if it didn't, mixing files from an 
old cluster with the new clone would corrupt it. Wipe first, clone into a clean directory.

```bash
docker compose --profile standby stop standby-db 2>/dev/null || true

# wipe any old standby files
rm -rf ./data/standby/*
mkdir -p ./data/standby
```

### 4.2 Run `pg_basebackup` into the standby volume

**Why a throwaway container:** the `standby-db` container cannot do this itself - it isn't running yet (its data 
directory is empty). Instead, spin up a one-off `postgres:18` container (`docker run --rm`) that:

- joins the same Docker network (`--network pg-net`) so it can reach `primary-db` by hostname
- mounts the **standby's host volume** (`./data/standby`) so the clone lands exactly where `standby-db` will later 
  look for its PGDATA
- runs `pg_basebackup` as a **client**, connecting to the `primary` over the replication protocol (the same 
  `walsender` channel a live `standby` uses - not a normal SQL connection)

The connection flow is: throwaway container → `primary-db:5432` → authenticated as `repl` via the 
`host replication repl` line from section 2.3 → `primary` streams every file + live WAL back → files written into 
`./data/standby/18/docker`.

Official `postgres:18` stores PGDATA under `/var/lib/postgresql/18/docker` when the volume is mounted at `/var/lib/postgresql`.

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
      -h primary-db \
      -p 5432 \
      -U repl \
      -D /var/lib/postgresql/18/docker \
      -R \
      -X stream \
      -P \
      -S standby1_slot
  '
```

What the flags mean:

| Flag               | Purpose                                                                                                                                                                                                                                        |
|--------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `-h primary-db`    | Connect to the `primary` over the Docker network (`pg-net` resolves the hostname)                                                                                                                                                              |
| `-p 5432`          | The `primary`'s port **inside** the network (not the host-mapped one)                                                                                                                                                                          |
| `-U repl`          | Authenticate as the replication role from section 2.2                                                                                                                                                                                          |
| `-D ...`           | Target PGDATA - where the clone is written                                                                                                                                                                                                     |
| `-R`               | The magic flag: writes `standby.signal` (marker: "start in recovery mode, stay read-only") and appends `primary_conninfo` to `postgresql.auto.conf` ("here is how to reach the `primary`") - this is what turns a plain clone into a `standby` |
| `-X stream`        | Open a **second** connection that streams WAL generated *while* the copy runs → the backup is self-contained and consistent                                                                                                                    |
| `-P`               | Show progress (nice for large clusters)                                                                                                                                                                                                        |
| `-S standby1_slot` | Attach to the physical slot from section 3, so the `primary` retains WAL from this exact moment onward - closes the gap between "backup finished" and "standby started"                                                                        |

Without `-R`, the clone would boot as a **second independent primary** (accepting writes, diverging immediately). 
Without `-S`, a busy `primary` could recycle the WAL the `standby` needs before it even starts.

📚 Reference: 
- [8_Standby_Initialization.md](./8_Standby_Initialization.md) - what `standby.signal` and `primary_conninfo` do at 
- startup.

If skipped section 3 and the slot does not exist yet, create it during the backup instead:

```bash
# replace the -S line with:
#   -C -S standby1_slot
```

### 4.3 Confirm the seed looks right

**Why:** two files decide the `standby`'s identity, so verify them *before* starting the container:

- `standby.signal` → without it, the clone starts as a writable `primary` (dangerous - it would silently diverge)
- `primary_conninfo` in `postgresql.auto.conf` → without it, the `standby` replays local WAL and then just stops, 
  never connecting to stream more

```bash
ls ./data/standby/18/docker | head
test -f ./data/standby/18/docker/standby.signal && echo "standby.signal OK"
grep primary_conninfo ./data/standby/18/docker/postgresql.auto.conf
```

Expected:

- `standby.signal` exists
- `postgresql.auto.conf` contains `primary_conninfo=...host=primary-db...user=repl...`
- Directories like `base/`, `global/`, `pg_wal/` exist

If `primary_slot_name` is missing after backup, add it:

```bash
# optional hardening - pin the slot on the standby side
docker run --rm \
  -v "$(pwd)/data/standby:/var/lib/postgresql" \
  postgres:18 \
  bash -c '
    echo "primary_slot_name = '\''standby1_slot'\''" \
      >> /var/lib/postgresql/18/docker/postgresql.auto.conf
  '
```

---

## 5. Start the `standby`

**Why this "just works":** the postgres image only runs `initdb` when the data directory is empty. Ours is already 
populated by `pg_basebackup`, so the container boots straight into the cloned cluster. On startup the Startup Process 
sees `standby.signal` and runs the standby sequence:

1. Replay local WAL (crash-recovery style) until consistent
2. Use `primary_conninfo` to start a **WAL Receiver** and connect to the `primary`
3. Keep replaying the incoming stream forever - and open for **read-only** queries (hot standby)

There is no "done" state - recovery mode *is* the `standby`'s normal life.

📚 Reference: 
- [8_Standby_Initialization.md](./8_Standby_Initialization.md) - the full startup sequence,
- [1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md) - WAL Receiver / Startup Process.

```bash
docker compose --profile standby up -d standby-db
docker compose --profile standby ps
docker logs standby-db --tail 40
```

Look for messages about recovery / streaming / ready to accept read-only connections.

Confirm role:

```bash
docker exec -it standby-db \
  psql -U prPostgres -d testDB -c "SELECT pg_is_in_recovery();"
```

Expected: `t`

Prove it is read-only (a `standby` in recovery mode rejects all writes - this failing is *success*):

```bash
docker exec -it standby-db \
  psql -U prPostgres -d testDB \
  -c "CREATE TABLE should_fail (id int);"
```

Expected: `cannot execute CREATE TABLE in a read-only transaction` (or similar).

---

## 6. Prove streaming replication

**Why three checks:** "the container is up" proves nothing about replication. Verify all three layers:

1. **Connection** - the `primary` sees a WAL Sender serving a `standby` (`pg_stat_replication`)
2. **Retention** - the slot is active, so WAL is being retained and consumed (`pg_replication_slots`)
3. **Data** - a real write on the `primary` becomes visible on the `standby` (the end-to-end proof)

📚 Reference: 
- [4_LSN.md](./4_LSN.md) - what `sent_lsn` / `replay_lsn` mean and how to read lag in bytes.

### 6.1 On the `primary` - is a standby connected?

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT application_name,
       client_addr,
       state,
       sync_state,
       sent_lsn,
       write_lsn,
       flush_lsn,
       replay_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
SQL
```

Expected: **one row**, `state = streaming`.

### 6.2 Slot status

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT slot_name, active, restart_lsn, wal_status
FROM pg_replication_slots;
SQL
```

Expected: `standby1_slot` with `active = t` (if the standby is using the slot).

### 6.3 Create data on the `primary`, read it on the `standby`

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
CREATE TABLE IF NOT EXISTS events (
  id serial PRIMARY KEY,
  tag text NOT NULL,
  created_at timestamptz DEFAULT now()
);

INSERT INTO events (tag)
SELECT 'bootstrap-' || g
FROM generate_series(1, 20) AS g;

SELECT count(*), min(tag), max(tag) FROM events;
SQL
```

On the `standby`:

```bash
docker exec -it standby-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_is_in_recovery();
SELECT count(*), min(tag), max(tag) FROM events;
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
SQL
```

Expected:
- Same row count on both
- Tags match
- Standby still in recovery (`t`)

---

## 7. Quick health checklist

Run this any time want a one-screen "is replication OK?" check.

**Primary:**

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_is_in_recovery() AS is_standby;          -- expect f
SELECT pg_current_wal_lsn();
SELECT state, sync_state, replay_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
SQL
```

**Standby:**

```bash
docker exec -it standby-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_is_in_recovery() AS is_standby;          -- expect t
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
SELECT count(*) FROM events;
SQL
```

---

## 8. Useful day-to-day commands

```bash
# start / stop
docker compose up -d primary-db
docker compose --profile standby up -d standby-db
docker compose --profile standby stop
docker compose --profile standby down

# logs
docker logs -f primary-db
docker logs -f standby-db

# shells
docker exec -it primary-db psql -U prPostgres -d testDB
docker exec -it standby-db  psql -U prPostgres -d testDB

# where is PGDATA?
docker exec -it primary-db psql -U prPostgres -Atc "SHOW data_directory;"
docker exec -it standby-db  psql -U prPostgres -Atc "SHOW data_directory;"

# list WAL files
docker exec -it primary-db bash -c 'ls -lh "$(psql -U prPostgres -Atc "SHOW data_directory")/pg_wal" | head'
docker exec -it standby-db  bash -c 'ls -lh "$(psql -U prPostgres -Atc "SHOW data_directory")/pg_wal" | head'
```

---

## 9. Full rebuild from scratch (cheat sheet)

**Why this is the universal fix:** once the `primary` has recycled WAL the `standby` needs, no amount of waiting or 
restarting closes the gap - the diffs are gone, so the only option is a fresh clone. Common triggers and how to avoid 
them are covered in [10_Replication_Failure_Scenarios.md](./10_Replication_Failure_Scenarios.md).

When replication is broken beyond repair (WAL removed, corrupt standby, etc.):

```bash
cd postgres-learning

docker compose --profile standby down
rm -rf ./data/primary ./data/standby
mkdir -p ./data/primary ./data/standby

# 1) primary
docker compose up -d primary-db
# wait for ready, then re-run sections 2–3 (config + role + hba + slot)

# 2) seed standby (section 4)
# 3) start standby (section 5)
# 4) verify (section 6)
```

---

## Troubleshooting

| Symptom                                          | Likely cause                                         | Fix                                                   |
|--------------------------------------------------|------------------------------------------------------|-------------------------------------------------------|
| `pg_basebackup` auth failed                      | Wrong password / no `repl` role / `pg_hba` missing   | Re-check section 2                                    |
| `requested WAL segment has already been removed` | No slot / standby offline too long                   | Rebuild standby + use a slot                          |
| `pg_stat_replication` empty                      | Standby not running, bad `primary_conninfo`, network | Check logs, `standby.signal`, Docker network `pg-net` |
| Standby accepts writes                           | Missing `standby.signal` (started as a fork)         | Re-seed with `pg_basebackup -R`                       |
| Port already in use                              | Host `:5432` / `:5433` taken                         | Stop the other Postgres or change ports in compose    |
| Permission errors on `./data`                    | Host directory ownership                             | Fix ownership or recreate `./data/*`                  |

Standby logs are usually the fastest signal:

```bash
docker logs standby-db --tail 100
```

---

## What each step taught

| Step                                      | Concept                                                     |
|-------------------------------------------|-------------------------------------------------------------|
| Configure `wal_level` / `max_wal_senders` | `primary` must generate WAL rich enough to stream           |
| `CREATE ROLE ... REPLICATION` + `pg_hba`  | Replication uses a special privilege and auth path          |
| `pg_basebackup -R -X stream`              | Seed once: full cluster clone + repair WAL + standby config |
| `standby.signal` / `primary_conninfo`     | What makes a clone a follower                               |
| `pg_stat_replication`                     | Live proof the WAL stream is connected                      |
| Insert on `primary`, select on `standby`  | Async physical replication is working                       |

Next: run the hands-on concept labs in [`../lab/`](../lab/README.md) (LSN lag, pause replay, slots, partition, sync commit, promotion, diagnosis).

---

## References

- [1_PostgreSQL_Architecture.md](./1_PostgreSQL_Architecture.md) - `PGDATA`, server processes, `pg_hba.conf`
- [2_WAL.md](./2_WAL.md) - `wal_level`, WAL lifecycle
- [4_LSN.md](./4_LSN.md) - reading `sent_lsn` / `replay_lsn` / lag
- [5_Checkpoint.md](./5_Checkpoint.md) - why WAL gets recycled
- [6_Replication_Slots.md](./6_Replication_Slots.md) - slots vs `wal_keep_size`
- [7_Base_Backup.md](./7_Base_Backup.md) - `pg_basebackup` in depth
- [8_Standby_Initialization.md](./8_Standby_Initialization.md) - `standby.signal`, startup sequence
- [10_Replication_Failure_Scenarios.md](./10_Replication_Failure_Scenarios.md) - when rebuilds are needed
- [docker-compose.yaml](../docker-compose.yaml)
- [PostgreSQL - pg_basebackup](https://www.postgresql.org/docs/current/app-pgbasebackup.html)
- [PostgreSQL - Streaming Replication](https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION)
