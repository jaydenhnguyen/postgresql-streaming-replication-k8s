# Lab 11 — Promotion and Row Reconciliation

**Goal:** Promote the `standby` during a write load, measure what survived, and explain losses with LSNs. Practice fencing awareness (split-brain).

**Theory:** [9_Promotion.md](../notes/9_Promotion.md), [4_LSN.md](../notes/4_LSN.md)

**Prerequisite:** Labs 00, 03. Prefer **async** mode (Lab 10 left async).

**Warning:** After this lab the roles flip. Use the reset section to rebuild a normal primary/standby pair.

---

## Steps

### 1. Prepare a countable table

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
DROP TABLE IF EXISTS lab11_promo;
CREATE TABLE lab11_promo (
  id bigserial PRIMARY KEY,
  tag text NOT NULL,
  created_at timestamptz DEFAULT now()
);
INSERT INTO lab11_promo (tag) VALUES ('seed');
SELECT count(*) FROM lab11_promo;
SQL
```

### 2. Start a write loop on the primary (Terminal A)

```bash
docker exec -it primary-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_current_wal_lsn() AS primary_lsn_start;
DO $$
BEGIN
  FOR i IN 1..5000 LOOP
    INSERT INTO lab11_promo (tag) VALUES ('load-' || i);
    PERFORM pg_sleep(0.002);
  END LOOP;
END $$;
SQL
```

(Shorter loop is fine if your machine is slow — note how many you aimed for.)

### 3. Snapshot standby replay LSN (Terminal B) — then promote

While the loop runs (or immediately after pausing replay for a bigger gap — optional Lab 04 trick):

```bash
docker exec -it standby-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_last_wal_receive_lsn() AS receive;
SELECT pg_last_wal_replay_lsn()  AS replay_before_promote;
SELECT count(*) AS rows_before_promote FROM lab11_promo;
SELECT pg_is_in_recovery();
SELECT pg_promote();
SELECT pg_is_in_recovery();
SQL
```

| Metric | Value |
|--------|-------|
| `replay_before_promote` | |
| `rows_before_promote` | |
| `pg_is_in_recovery()` after promote | must become `f` |

### 4. Stop / fence the old primary (critical)

```bash
docker compose stop primary-db
```

| Why fence? | Your answer |
|------------|-------------|
| What is split-brain if old primary keeps accepting writes? | |

### 5. Row reconciliation

On the **new primary** (old standby container `standby-db`):

```bash
docker exec -it standby-db \
  psql -U prPostgres -d testDB <<'SQL'
SELECT pg_is_in_recovery();          -- expect f
SELECT count(*) FROM lab11_promo;
INSERT INTO lab11_promo (tag) VALUES ('post-promote-write');
SELECT max(id), count(*) FROM lab11_promo;
SQL
```

On the **old primary** (if you start it briefly **read-only for forensics only** — do not let apps write):

```bash
# optional forensics — prefer leaving it stopped
# docker compose start primary-db
# then compare counts — then STOP again immediately
```

| Counter | Value |
|---------|-------|
| Rows on new primary after promote | |
| Rows on old primary (if checked) | |
| Estimated lost committed rows | |
| LSN explanation (one sentence) | |

### 6. Second promotion method (optional)

Reset via Lab 00 rebuild first if roles are messy, then try:

```bash
# On a standby in recovery:
# touch $(psql ... -Atc "SHOW data_directory")/promote   # trigger file method
# or: pg_ctl promote -D "$PGDATA"
```

| Method | Tried? | Result |
|--------|--------|--------|
| `pg_promote()` | | |
| `pg_ctl promote` / trigger file | | |

---

## Expected outcome

- [ ] `pg_is_in_recovery()` flips `t` → `f` on promoted node
- [ ] Post-promote write succeeds on new primary
- [ ] Old primary stopped (fenced)
- [ ] Can explain any row gap using replay LSN vs primary LSN

---

## Reset (return to normal lab topology)

Promotion breaks the original roles. Clean rebuild:

```bash
cd postgres-learning
docker compose --profile standby down
rm -rf ./data/primary ./data/standby
mkdir -p ./data/primary ./data/standby
# Re-run Lab 00 completely
```

---

## Takeaway

> Promotion is one-way. Async loss = commits that existed on the old primary **after** the standby's last **replay** LSN. Always fence the old primary.



Next: [12_Failure_Diagnosis_Drill.md](./12_Failure_Diagnosis_Drill.md)
