# Lab 10 - Sync vs Async Commit

**Goal:** Feel the durability vs availability tradeoff: async can lose acked commits on failover; sync waits for the standby (and can block).

**Theory:** [9_Promotion.md](../notes/9_Promotion.md), [4_LSN.md](../notes/4_LSN.md)

**Prerequisite:** Healthy streaming pair (Lab 00). Prefer finishing Labs 03–04 first.

---

## Background (one screen)

| Mode | `COMMIT` returns when... | Failover row loss for acked commits |
|------|--------------------------|-------------------------------------|
| Async (default) | Local WAL flush on primary | Possible if standby behind |
| Sync (`synchronous_commit=on` + sync standby named) | Standby has flushed that WAL | Zero for acked commits |

---

## Steps

### 1. Confirm current mode (async baseline)

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SHOW synchronous_commit;
SHOW synchronous_standby_names;
SELECT application_name, sync_state, state FROM pg_stat_replication;
SQL
```

| Setting | Value |
|---------|-------|
| `synchronous_commit` | (often `on` locally but without sync standby names → still async to standby) |
| `synchronous_standby_names` | (empty = no sync standby) |
| `sync_state` of standby | expect `async` |

### 2. Async mental drill (required)

Imagine: primary commits rows 1..100; standby replay LSN still at row 80; primary dies; you promote.

| Question | Answer |
|----------|--------|
| Which committed rows can be lost? | |
| Which LSN comparison proves it? | |

### 3. Enable synchronous replication (lab)

Use the standby's `application_name` (often `walreceiver` or from `pg_stat_replication`):

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB \
  -c "SELECT application_name, sync_state FROM pg_stat_replication;"
```

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
-- Adjust name if your application_name differs
ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (walreceiver)';
ALTER SYSTEM SET synchronous_commit = on;
SELECT pg_reload_conf();
SHOW synchronous_standby_names;
SELECT application_name, sync_state, state FROM pg_stat_replication;
SQL
```

If `sync_state` stays `async`, set `application_name` on the standby via `primary_conninfo` (add `application_name=standby1`) and restart standby, then use that name in `synchronous_standby_names`.

| After sync config | Value |
|-------------------|-------|
| `sync_state` | want `sync` |
| How you fixed naming (if needed) | |

### 4. Prove COMMIT waits when standby is down

```bash
# Terminal A: stop standby
docker compose --profile standby stop standby-db

# Terminal B: this INSERT should BLOCK until timeout / standby returns
docker exec -it primary-db \
  psql -U prPostgres -d testDB \
  -c "INSERT INTO events (tag) VALUES ('sync-block-test');"
```

| Observation | Value |
|-------------|-------|
| Did the INSERT block? | |
| What does that teach about availability? | |

Restore:

```bash
docker compose --profile standby up -d standby-db
# blocked session should complete (or cancel it with Ctrl-C and retry)
```

### 5. Return to async for later labs (important)

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
ALTER SYSTEM SET synchronous_standby_names = '';
ALTER SYSTEM SET synchronous_commit = on;  -- local durability OK; no sync standby
SELECT pg_reload_conf();
SELECT application_name, sync_state FROM pg_stat_replication;
SQL
```

| Check | Expected |
|-------|----------|
| `sync_state` | `async` again |

---

## Expected outcome

- [ ] Can explain async loss at promotion using LSNs
- [ ] Saw (or reasoned) that sync COMMIT blocks if standby unavailable
- [ ] Lab left back on async for Lab 11

---

## Takeaway

> Sync buys **zero loss of acked commits** and sells **availability** - the insert loop stalls if the sync standby is gone.



Next: [11_Promotion_and_Row_Reconciliation.md](./11_Promotion_and_Row_Reconciliation.md)
