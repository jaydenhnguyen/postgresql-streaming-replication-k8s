# PostgreSQL Streaming Replication - Lab Track

Hands-on labs to master every concept needed for this project (Docker first, then map the same ideas to Kubernetes).

Work from `postgres-learning/`. Complete labs **in order**. Each lab has:

- **Goal** - what you are proving
- **Theory** - which note to read first
- **Steps** - exact commands
- **Observation log** - fill in what you saw
- **Expected outcome** - pass criteria
- **Takeaway** - one sentence you should be able to say out loud

---

## Environment (shared)

| Item | Value |
|------|-------|
| Working directory | `postgres-learning/` |
| Compose file | `docker-compose.yaml` |
| Primary | `primary-db` → host `:5432` |
| Standby | `standby-db` → host `:5433` (profile `standby`) |
| Network | `pg-net` |
| Superuser | `prPostgres` / `p@sswoord123` |
| Database | `testDB` |
| Replication user | `repl` / `qwe123123` |
| Slot name | `standby1_slot` |

```bash
cd postgres-learning

# helpers used in many labs
alias px='docker exec -it primary-db psql -U prPostgres -d testDB'
alias sx='docker exec -it standby-db  psql -U prPostgres -d testDB'
```

**Prerequisite for labs 01–12:** streaming pair is up (finish [00](./00_Bootstrap_Primary_Standby.md) first).

---

## Lab map

| # | Lab | Master this | Theory notes |
|---|-----|-------------|--------------|
| [00](./00_Bootstrap_Primary_Standby.md) | Bootstrap primary + standby | Seed with `pg_basebackup`, prove streaming | 7, 8, 1 |
| [01](./01_PGDATA_Anatomy.md) | PGDATA anatomy tour | Cluster layout, processes, `pg_hba` | 1 |
| [02](./02_Commit_Flow_and_WAL.md) | Commit flow + WAL | WAL-first durability, dirty pages, `pg_wal/` | 2, 3 |
| [03](./03_LSN_Lag_Measurement.md) | LSN lag measurement | Three LSN functions + lag bytes | 4 |
| [04](./04_Pause_Replay.md) | Pause replay | Receive vs replay gap | 4, 8 |
| [05](./05_Checkpoints_and_Recycling.md) | Checkpoints + recycling | Timeout vs `max_wal_size`, recycle | 5, 2 |
| [06](./06_Replication_Slots.md) | Replication slots | Slot bookmark, retention, risk | 6 |
| [07](./07_Slot_vs_No_Slot_Failure.md) | Slot vs no-slot failure | Why slots prevent "WAL removed" | 6, 10 |
| [08](./08_Network_Partition.md) | Network partition | Disconnect, catch-up, slot protects | 10 |
| [09](./09_WAL_Removed_Rebuild.md) | WAL removed → rebuild | Re-seed with `pg_basebackup` | 7, 10 |
| [10](./10_Sync_vs_Async_Commit.md) | Sync vs async commit | Durability vs availability tradeoff | 11, 9, 4 |
| [11](./11_Promotion_and_Row_Reconciliation.md) | Promotion + row count | Promote under load, explain lost rows | 9, 4 |
| [12](./12_Failure_Diagnosis_Drill.md) | Failure diagnosis drill | Capstone: diagnose without looking up | 10 |

---

## How to use each lab

1. Read the linked theory note(s) once.
2. Run the steps; **fill the Observation log** (do not skip - this is what you will explain in the demo).
3. Check **Expected outcome**. If it fails, use Troubleshooting in that lab, then [12](./12_Failure_Diagnosis_Drill.md).
4. Write the **Takeaway** in your own words before moving on.

Optional: keep a dated scrap file `lab/observations.md` with all filled logs for the oral demo.

---

## Project mapping (why these labs)

| Project demo / oral ask | Which lab drills it |
|-------------------------|---------------------|
| Prove streaming + seeded data | 00, 03 |
| Standby is read-only | 00, 01 |
| LSN gap idle vs under write load | 03, 04 |
| Promote during insert loop + row accounting | 11 |
| Why `synchronous_commit = on` changes loss | 10 |
| Split-brain / old primary still up | 11 |
| WAL gone / rebuild | 07, 09 |
| Slot vs soft keep | 05, 06, 07 |

---

## Reset helpers

```bash
# stop both
docker compose --profile standby down

# nuclear rebuild (destroys lab data)
rm -rf ./data/primary ./data/standby
mkdir -p ./data/primary ./data/standby
# then re-run lab 00
```

Theory notes live in [`../notes/`](../notes/).
