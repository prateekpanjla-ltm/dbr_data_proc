# GH Archive Pipeline — Learnings & Runbook

_Compiled from debugging, development, and architecture discussions (2026-03-26)_

---

## 1. Incident: Silver Streaming Table Checkpoint Mismatch

### Symptom
V2 pipeline scheduled runs were triggering on time (every hour at :00 IST) but failing consistently. Ingest task and bronze succeeded; silver failed every time.

### Root Cause
**Error**: `DIFFERENT_DELTA_TABLE_READ_BY_STREAMING_SOURCE`

The `gharchive_bronze` table was **dropped and recreated**, assigning it a new Delta table ID (`3b8d78cb`). The silver streaming table's checkpoint still referenced the old table ID (`be8e2694`). Structured Streaming validates the source table ID on each micro-batch and rejects mismatches.

### Fix Applied
Selective **full refresh** of `gharchive_silver` only (not bronze) via the DLT pipeline UI.

### Prevention
- **Never drop and recreate** a Delta table that has downstream streaming consumers.
- Use `INSERT INTO` / `MERGE` / `APPEND` instead of recreating tables.
- If recreation is unavoidable, full refresh all downstream streaming tables.

---

## 2. DLT Refresh Semantics

### Refresh Types

| Update Type | Streaming Table | Materialized View |
|---|---|---|
| **Default refresh** | Processes only NEW records via checkpoint | Recomputes (DLT may optimize incrementally) |
| **Full refresh** | Clears checkpoint + data, reprocesses ALL from source | Full recompute from scratch |
| **Reset checkpoints** | Clears checkpoint only (keeps data), reprocesses all | N/A |

### Selective Refresh (UI)
1. Go to the **pipeline monitoring page** (not the editor)
2. Look for **"Refresh failed tables"** button (appears after failures)
3. Click dropdown (▾) → **"Select tables for refresh"**
4. Pick specific tables, optionally toggle "Full refresh"
5. Click "Refresh selection"

**Note**: If you only see "Full refresh", "Dry run", and "Run with different settings" in the Start dropdown — you're on the main Start button. The selective option is next to "Refresh failed tables".

### Key Insight: Excluded Tables Don't Run
When you selectively refresh only silver, gold tables are **EXCLUDED** from that update entirely — they won't refresh even if they depend on silver. You need a separate update (default refresh) to refresh gold.

---

## 3. Manual Equivalent of DLT Full Refresh (Structured Streaming)

If you had to full-refresh a streaming table without DLT, you'd need:

```
Step 1: TRUNCATE TABLE gharchive_silver          -- Clear target data
Step 2: dbutils.fs.rm(checkpoint_path, True)     -- Delete streaming checkpoint
Step 3: spark.readStream.table("bronze")         -- Restart stream (read-only on bronze)
            .writeStream
            .option("checkpointLocation", path)
            .toTable("silver")
```

**Reading from bronze ≠ refreshing bronze.** The readStream is a read-only consumer.

DLT automates all of this: checkpoint management, table lifecycle, retry logic, and downstream orchestration — behind a single `@dp.table` decorator and one button.

---

## 4. Medallion Architecture — Streaming vs Batch by Layer

### Standard Pattern

| Layer | Type | Why |
|---|---|---|
| **Bronze** | Streaming Table | Append-only raw ingestion — just add new data |
| **Silver** | Streaming Table | Row-level transforms (flatten, parse) — processable per record |
| **Gold** | Materialized View | Aggregations, rankings — need full dataset for correctness |

### Why Gold Uses Batch Reads
Our gold tables use `countDistinct`, `orderBy`, and ranking logic — these require scanning the **entire dataset** to produce correct results. Streaming's append-only model can't handle this without maintaining massive state.

### When Streaming Gold Works
Aggregations that are **commutative and associative** can be streamed:

| Aggregation | Commutative? | Streamable? |
|---|---|---|
| `count`, `sum` | Yes | Yes |
| `min`, `max` | Yes | Yes |
| `avg` (via sum/count) | Yes | Yes |
| `countDistinct` | **No** | No — needs full state |
| `percentile`, `median` | **No** | No |
| Rankings / `ORDER BY` | **No** | No — global reorder needed |

### Workaround: Making countDistinct Streamable
Break it into two streaming-friendly steps:
1. **Dedup table** (streaming): Append only newly seen distinct values, e.g., one row per unique `(repo_name, actor_login)` pair
2. **Gold table** (streaming): Simple `count(*)` over the dedup table — fully commutative

Tradeoff: Adds complexity + storage. Only worth it at scale where full recomputes become expensive.

---

## 5. V2 vs V3 Pipeline Architecture

| Aspect | V2 Pipeline | V3 Auto Loader |
|---|---|---|
| Bronze ingestion | `spark.readStream.table()` | `cloudFiles` (Auto Loader) |
| File tracking | Manual `latest/` → `archive/` rotation | Auto Loader checkpoint (automatic) |
| Ingest volume | `/Volumes/.../v2_pipeline/files/latest/` | `/Volumes/.../raw/files/` (flat) |
| Silver reads via | `spark.readStream.table()` | `dp.read("bronze")` |
| Gold reads via | `spark.read.table()` | `dp.read("silver")` |
| Gold type | `@dp.materialized_view` | `@dp.table` |
| Notebook layout | Separate notebooks per layer | Single notebook |
| Ingest task | Downloads + manages latest/archive dirs | Downloads + skips existing (simpler) |

### V3 Auto Loader Advantages
- No `DIFFERENT_DELTA_TABLE_READ_BY_STREAMING_SOURCE` risk from file rotation — Auto Loader tracks files by checkpoint, not table ID
- Simpler ingest — no directory management, just drop files into volume
- `dp.read()` lets DLT handle streaming/batch resolution automatically

---

## 6. Pipeline Recovery Verification

After fixing the silver checkpoint issue, the V2 pipeline fully recovered:

| Table | Rows | Status |
|---|---|---|
| `gharchive_bronze` | 635,588 | ✓ Healthy (4 source files) |
| `gharchive_silver` | 635,588 | ✓ Exact match with bronze |
| `gharchive_gold_activity_counts` | 64 | ✓ Created after default refresh |
| `gharchive_gold_top_repos` | 234,897 | ✓ Created after default refresh |
| `gharchive_gold_top_actors` | 171,512 | ✓ Created after default refresh |

**Verification approach**: Compare row counts across layers, correlate bronze source files with volume contents, check event time ranges match.

---

## 7. Operational Notes

### DLT Event Log Queries
Use `event_log('<pipeline_id>')` to investigate pipeline runs:
```sql
-- Recent errors
SELECT timestamp, level, message, origin.flow_name,
       error.exceptions[0].message as error_message
FROM event_log('<pipeline-id>')
WHERE level = 'ERROR'
ORDER BY timestamp DESC

-- Per-flow status in latest update
SELECT origin.flow_name, message
FROM event_log('<pipeline-id>')
WHERE event_type = 'flow_progress'
  AND origin.update_id = (SELECT origin.update_id FROM event_log('<pipeline-id>') ORDER BY timestamp DESC LIMIT 1)
ORDER BY timestamp
```

### Workspace File (.py) Limitations
- `dbutils.widgets` is **not available** when running `.py` files from the workspace editor
- These files work correctly when executed as **job tasks** (spark_python_task)
- For interactive testing, use a notebook instead

### Databricks Asset Bundles
- "This file is part of a bundle" banner appears when a `databricks.yml` exists in a parent directory
- Does NOT require the bundle to have been deployed — mere presence of the YAML triggers it
- Safe to ignore if you haven't run `databricks bundle deploy`
- Edits in workspace won't sync back to the bundle source (Git repo)
- A future `bundle deploy` would overwrite workspace edits

---

## 8. Project Structure

```
dbr_data_proc/
├── databricks.yml                          # Bundle config (not yet deployed)
├── LEARNINGS.md                            # This file
├── .github/workflows/
│   ├── dabs-deploy.yml                     # Bundle CI/CD workflow
│   └── infra-deploy.yml                    # Terraform CI/CD workflow
├── infra/                                  # Terraform configs
│   ├── main.tf, variables.tf, outputs.tf
│   ├── dev.tfvars, test.tfvars
│   ├── bootstrap.sql, setup-dev.sql, setup-test.sql
│   └── workspace/workspace-permissions.tf
└── src/
    ├── v2_pipeline/                        # V2: Separate notebooks per layer
    │   ├── ingest.py                       # Downloads GH Archive → latest/archive dirs
    │   ├── bronze/                         # Bronze streaming table notebook
    │   ├── silver/                         # Silver streaming table notebook
    │   └── gold/                           # Gold materialized view notebook
    └── v3_autoloader/                      # V3: Single notebook + Auto Loader
        ├── ingest.py                       # Downloads GH Archive → flat volume dir
        └── pipeline                        # All layers in one notebook (bronze/silver/gold)
```

### Key Catalogs & Schemas
- **V2**: `gharchive_dev.v2_pipeline` — volume at `/Volumes/gharchive_dev/v2_pipeline/files/`
- **V3**: `gharchive_dev.raw` — volume at `/Volumes/gharchive_dev/raw/files/`

### Pipeline IDs
- **V2 Pipeline**: `81791988-c025-472b-8f65-7448ed881eab`
- **V2 Scheduled Job**: `815970454166232`
- **V3 Pipeline**: _(not yet created)_
- **V3 Scheduled Job**: _(not yet created)_

---

## 9. TODO / Next Steps

- [ ] Create DLT pipeline for V3 (pointing to `v3_autoloader/pipeline` notebook)
- [ ] Create scheduled job for V3 (ingest → run_pipeline, hourly)
- [ ] Consider deploying via Databricks Asset Bundles for CI/CD
- [ ] Evaluate whether V3 gold tables should use `@dp.materialized_view` instead of `@dp.table`
- [ ] Add monitoring/alerts for pipeline failures
