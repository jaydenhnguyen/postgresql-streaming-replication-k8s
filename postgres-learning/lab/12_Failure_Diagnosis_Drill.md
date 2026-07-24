# Lab 12 - Failure Diagnosis Drill (Capstone)

**Goal:** Diagnose common failures using only symptoms + a short checklist - no peeking at note 10 until you commit an answer.

**Theory (check after):** [10_Replication_Failure_Scenarios.md](../notes/10_Replication_Failure_Scenarios.md)

**Prerequisite:** Labs 00–11 concepts. Pair should be healthy (rebuild with Lab 00/09 if Lab 11 left roles flipped).

---

## How to run this drill

For each scenario:

1. Read **Symptom**.
2. Write **Likely cause** and **First three commands**.
3. Then reveal by checking the Answer key at the bottom (fold mentally - don't scroll early).

---

## Scenario A

**Symptom:** `pg_stat_replication` is empty. Standby container is `Up`. Primary accepts writes.

| Your diagnosis | |
|----------------|--|
| Likely cause | |
| Commands you would run | 1.  2.  3. |
| Fix | |

---

## Scenario B

**Symptom:** Standby log: `requested WAL segment 00000001000000000000000A has already been removed`.

| Your diagnosis | |
|----------------|--|
| Likely cause | |
| Is restart enough? | |
| Fix | |

---

## Scenario C

**Symptom:** Standby accepts `INSERT` successfully.

| Your diagnosis | |
|----------------|--|
| Likely cause | |
| Danger | |
| Fix | |

---

## Scenario D

**Symptom:** Idle lag shows a few KB; under `INSERT` burst lag jumps to many MB then falls.

| Your diagnosis | |
|----------------|--|
| Is this broken? | |
| What are you measuring? | |

---

## Scenario E

**Symptom:** Slot `active = f` for hours; `pg_wal` directory growing fast; disk alarm.

| Your diagnosis | |
|----------------|--|
| Risk | |
| Mitigations | |

---

## Scenario F

**Symptom:** After promote, both old primary and new primary accept writes; row sets diverge.

| Your diagnosis | |
|----------------|--|
| Name of failure mode | |
| Prevention | |

---

## Scenario G

**Symptom:** With sync standby configured, application `COMMIT` hangs when standby pod is killed.

| Your diagnosis | |
|----------------|--|
| Is primary "down"? | |
| Tradeoff being demonstrated | |

---

## Hands-on mini circuit (optional)

Pick any three scenarios and **reproduce** them briefly using Labs 04, 07, 08, 10, or 11. Log:

| Scenario | Reproduced? | Time to diagnose |
|----------|-------------|------------------|
| | | |
| | | |
| | | |

---

## Mastery checklist (project oral)

Tick when you can explain without notes:

- [ ] Why `wal_level=replica` and a `REPLICATION` role are required
- [ ] What `pg_basebackup -R -X stream` produces
- [ ] `pg_is_in_recovery()` on each role
- [ ] Lag = `pg_wal_lsn_diff(primary, replay)`
- [ ] Receive vs replay (Lab 04)
- [ ] Checkpoint vs slot
- [ ] `max_wal_size` vs `wal_keep_size` vs `checkpoint_timeout`
- [ ] Why missing WAL → rebuild only
- [ ] Async loss at promote + fencing
- [ ] Sync commit blocks when standby is gone

---

## Answer key (check after)

**A:** Bad/missing `primary_conninfo`, wrong network, auth/`pg_hba`, or WAL receiver not running → check standby logs, `standby.signal`, `postgresql.auto.conf`, Docker network.

**B:** Needed WAL recycled (no slot / slot lost / keep size too small) → **rebuild** with `pg_basebackup`; restart will not recreate deleted segments.

**C:** Missing `standby.signal` (started as independent primary) → dangerous divergence → re-seed with `-R`.

**D:** Normal async behavior → LSN byte lag under load; not a failure by itself.

**E:** Abandoned slot retaining WAL → disk fill risk → fix consumer or drop slot; consider `max_slot_wal_keep_size`.

**F:** Split-brain → fence old primary (stop/network kill) before/at promote; never two writers.

**G:** Synchronous replication doing its job → durability over availability; COMMIT waits for sync standby.

---

## Takeaway

> Healthy streaming is not "containers up" - it is **streaming state + LSN progress + correct roles + retained WAL**. Diagnosis starts with logs, `pg_stat_replication`, slots, and `pg_is_in_recovery()`.

---

## After the lab track

You are ready to map the same ideas onto Kubernetes (`initContainer` ≈ Lab 00 seed, lag script ≈ Lab 03, promote ≈ Lab 11). Theory remains in [`../notes/`](../notes/).
