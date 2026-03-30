# GH Archive Pipeline - Open Questions & Design Discussions

_Captured from architecture and design discussions (2026-03-26)_

---

## 1. Platform Lock-in vs Managed Convenience

### The Tradeoff
More managed convenience = more platform lock-in:

| Approach | Lock-in | Operational Burden |
|---|---|---|
| Raw PySpark + Airflow | Minimal - runs anywhere | High - you manage everything |
| DLT with `spark.readStream` (V2 style) | Moderate - decorators DLT-specific, reads are standard Spark | Low |
| DLT with `dp.read()` + `cloudFiles` (V3 style) | Higher - more DLT-specific APIs | Lowest |
| Lakeflow Connect (SQL Server) | Highest - fully managed, zero custom code | Zero |

### Portability Breakdown

| Layer | Portable? | Details |
|---|---|---|
| PySpark transformations | Yes - fully portable | Standard Spark, runs anywhere |
| SQL logic | Mostly portable | Standard SQL works anywhere; `ai_*` functions are Databricks-only |
| `@dp.table`, `@dp.materialized_view` | No - Databricks only | DLT/SDP-specific decorators |
| `dp.read()` | No - Databricks only | DLT internal dependency resolution |
| Pipeline resource | No - Databricks only | Checkpoints, event log, refresh semantics |
| Auto Loader (`cloudFiles`) | No - Databricks only | Proprietary file ingestion |
| Delta Lake | Yes - open source | Runs on any Spark environment |

### Open Source Angle
Databricks donates to open source (Delta Lake, MLflow, Spark). But the orchestration and state
management layer is proprietary. Apache Spark Declarative Pipelines (Spark 4.1) will bring some
of this to open source, but won't include full operational features (event log, UI, selective refresh).

### V2 vs V3 Portability
V2 is more portable than V3 - it uses standard Spark streaming APIs (`spark.readStream.table()`).
V3's `dp.read()` and `cloudFiles` buy convenience at the cost of portability.

---

## 2. Why Does Databricks Have a Pipeline Abstraction?

### Pipeline = Run Configuration + State Manager + Orchestrator

In vanilla PySpark, all three concerns are tangled in your code:
- Checkpoint paths hardcoded in `.option("checkpointLocation", ...)`
- Target tables embedded in `.toTable()`
- Retry logic via try/except
- DAG ordering via manual script sequencing

DLT separates these into:
- **Logic layer**: `@dp.table` decorated functions (what to compute)
- **Configuration layer**: Pipeline resource (where to write, what compute)
- **Execution layer**: Pipeline updates (state, checkpoints, event log)

### Why the abstraction exists
Without it, every team reinvents:
1. A config system for checkpoint paths and output tables
2. A DAG scheduler for table dependencies
3. A state tracker for what's been processed
4. A retry framework for transient failures
5. A refresh mechanism to reset and reprocess
6. A monitoring system for run history

Same reason Kubernetes exists over Docker - operational burden of managing state,
dependencies, and environments at scale exceeds what's reasonable in application code.

### Universal Pattern Across Platforms

| Platform | Source Code (logic) | Runtime Resource (config + state) |
|---|---|---|
| Databricks DLT | Notebook with `@dp.table` | DLT Pipeline |
| Apache Airflow | DAG Python file | Scheduler + Worker + Metadata DB |
| dbt | `.sql` model files | Project execution with profile/target |
| Azure Data Factory | Pipeline JSON definition | ADF resource + triggers + integration runtime |
| AWS Glue | PySpark script in S3 | Glue Job + IAM + connections + bookmarks |
| Ab Initio | Graph (`.mp` file) | Plan + Co>Operating System deployment |
| DataStage | Job design (`.dsx`) | Project + Engine + Director scheduling |
| Informatica PowerCenter | Mapping in Designer | Session + Workflow in Workflow Manager |
| SSIS | `.dtsx` package | SQL Agent Job + SSIS Catalog |

---

## 3. Isolating Portable vs Non-Portable Code

### Recommended Pattern: Core + Platform Wrappers

```
project/
  core/                        # 100% portable, runs anywhere
    transforms.py              #   Pure PySpark functions
    schemas.py                 #   Schema definitions
  platform_dlt/                # Databricks DLT wrappers
    pipeline.py                #   @dp.table + dp.read()
  platform_airflow/            # Airflow alternative
    dag.py                     #   readStream + writeStream
  platform_glue/               # AWS Glue alternative
    job.py                     #   GlueContext wiring
```

### Core Layer (portable):
- Pure PySpark functions: `bronze_to_silver(df) -> DataFrame`
- No platform imports, no decorators, no checkpoint management
- Schema definitions as plain `StructType` objects
- Unit testable with any Spark session

### Platform Layer (thin wrappers):
- DLT: `@dp.table` + `dp.read()` + `cloudFiles`
- Airflow: `spark.readStream` + `.writeStream` + manual checkpoints
- Glue: `GlueContext` + job bookmarks

### What changes between platforms:

| Code | DLT | Vanilla Spark | Changed? |
|---|---|---|---|
| `bronze_to_silver()` | Called as-is | Called as-is | No |
| `silver_to_gold_activity()` | Called as-is | Called as-is | No |
| Schema definitions | Shared | Shared | No |
| How bronze reads files | `cloudFiles` | `spark.readStream.json()` | Yes |
| How silver reads bronze | `dp.read()` | `spark.readStream.table()` | Yes |
| Checkpoint management | Automatic | Manual `.option()` | Yes |
| Orchestration | DLT DAG resolution | Airflow task dependencies | Yes |

Core transforms are identical across platforms. Only ~15 lines of wiring code change.
This follows **Hexagonal Architecture** (ports and adapters) - isolate domain logic
from infrastructure concerns.

### Practical Risk Mitigation:
- Keep transformations in plain PySpark (not `dp.read()`)
- Use Delta Lake (open source) as storage format
- Isolate DLT-specific code to thin wrapper layers
- Treat the pipeline resource as disposable - recreated per environment

---

## 4. Lakeflow Connect for 1000 SQL Server Tables

### Key Constraints
- Maximum **250 tables per pipeline**
- For 1000 tables: **4 pipelines** (not 1000 pipelines)
- Each pipeline is a single API call with up to 250 tables in `ingestion_definition.objects`
- Auto schema detection, incremental CDC, schema evolution included

### Open Questions
- How to handle table name conflicts across schemas?
- What's the monitoring story for 4 parallel ingestion pipelines?
- How to handle schema changes in source SQL Server tables?
- What's the fallback if Lakeflow Connect doesn't support a specific SQL Server feature?

---

## 5. Open TODOs

- [ ] Decide: Should V3 be refactored to use the portable core + wrapper pattern?
- [ ] Evaluate: Is portability tradeoff worth added complexity at current scale?
- [ ] Investigate: Apache Spark 4.1 Declarative Pipelines - how much of DLT becomes open source?
- [ ] Benchmark: V2 (standard Spark APIs) vs V3 (DLT-native APIs) - any performance difference?
- [ ] Consider: If migrating 1000 SQL Server tables, Lakeflow Connect vs DIY JDBC - cost comparison?
- [ ] Prototype: The portable core + wrapper pattern with one bronze/silver/gold chain
