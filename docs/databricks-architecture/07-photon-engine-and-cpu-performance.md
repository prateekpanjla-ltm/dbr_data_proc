# Photon Engine and CPU Performance

## What Is Photon?

Photon is a **query execution engine written entirely in C++** that replaces Spark's JVM-based execution layer. It sits inside the Databricks Runtime and is transparent to your code — SQL and DataFrame API calls look identical, but execution happens in native code instead of JVM bytecode.

## How Traditional Spark Executes vs. Photon

### Standard Spark (Volcano Model)
- Processes data **row by row** through a pipeline of operators
- Runs on the **JVM** — subject to GC pauses, object overhead, JIT compilation variability
- Each row passes through: scan → filter → project → aggregate → shuffle, one at a time
- JVM objects per row add ~16-32 bytes overhead per field (boxing, pointers, headers)

### Photon (Vectorized Columnar Model)
- Processes data in **batches of columns** (typically 1024-4096 values at a time)
- Runs as **native C++ code** — no GC pauses, no object overhead, direct memory management
- Columnar layout means the same operation (e.g., "filter where amount > 100") runs across a contiguous memory array
- Enables **CPU SIMD instructions** (Single Instruction, Multiple Data) — processes 4, 8, or 16 values in a single clock cycle
- Data stays in **CPU L1/L2 cache** because columnar batches are cache-line friendly

## Specific Optimizations

### 1. Scan & I/O (S3 Impact)
- **Faster Parquet decoding** in native C++ — data from S3 is processed sooner
- **Robust scan performance** on tables with many columns and many small files
- **Disk cache acceleration** — reads cached data faster than JVM (no serde overhead)
- **Predictive I/O for reads** — prefetches data files, overlapping I/O with computation

### 2. Joins & Aggregations
- **Replaces sort-merge joins with hash joins** — no expensive sort step
- **Vectorized hash aggregation** — GROUP BY processes column batches through hash tables in native code

### 3. Writes (Deletion Vectors)

| Operation | Without Photon | With Photon |
| --- | --- | --- |
| DELETE 1 row from 1 GB file | Rewrites entire 1 GB file to S3 | Marks row as deleted in tiny side-file (~bytes) |
| UPDATE 100 rows in 1 GB file | Rewrites entire file | Deletion vector for old rows + small supplemental file |
| MERGE (upsert) | Rewrites all matched files | Deletion vectors + supplemental writes — dramatically less I/O |

This is massive for S3 because every file rewrite = a full PUT of the entire Parquet file.

### 4. Dynamic File Pruning in DML
- For MERGE, UPDATE, DELETE: dynamically determines at runtime which files contain matching rows
- Skips files that don't contain matching data
- **Requires Photon** — not available in standard Spark

### 5. Features That Require Photon
- Predictive I/O for read and write
- Dynamic file pruning in MERGE, UPDATE, and DELETE statements

## Supported Operations

### Operators
Scan, Filter, Project, Hash Aggregate/Join/Shuffle, Nested-Loop Join, Null-Aware Anti Join, Union, Expand, ScalarSubquery, Delta/Parquet Write Sink, Sort, Window Function

### Data Types
Byte/Short/Int/Long, Boolean, String/Binary, Decimal, Float/Double, Date/Timestamp, Struct, Array, Map

### Limitations
- Does **not** support UDFs, RDD APIs, or Dataset APIs
- No stateful streaming support (stateless streaming with Delta/Parquet/CSV/JSON is supported)
- Doesn't impact queries under 2 seconds
- Unsupported operations **fall back to standard Spark** for the remainder of the workload

## When Photon Is Most Beneficial
- SQL workloads and DataFrame operations with complex transformations
- Joins, aggregations, and data scans on large tables
- Frequent disk access, wide tables, repeated data processing
- Simple batch ETL with small data volumes sees minimal impact

---

# CPU Utilization: The Hidden Truth

## The Common Misconception

It's tempting to think Photon makes the CPU "more utilized." In reality, **both JVM Spark and Photon show ~80-90% CPU utilization** in standard monitoring tools. The difference is throughput per CPU second.

## What JVM Spark's CPU Is Actually Doing

| Activity | Useful Work? |
| --- | --- |
| Decoding Parquet into JVM objects | Partially — creating Java objects (heap allocation, pointers, headers) is overhead |
| Garbage collection (stop-the-world pauses) | No — all application threads freeze while GC reclaims memory |
| Object boxing/unboxing (int → Integer) | No — pure JVM type system overhead |
| Virtual method dispatch (row-by-row iterator) | Partially — `next()` call chain adds branching overhead per row |
| CPU cache misses (objects scattered across heap) | No — CPU pipeline stalls waiting for memory. Shows as "busy" but CPU is stalling |
| JIT compilation (optimizing hot paths) | Delayed — warm-up cost at job start |

## What Photon's CPU Is Doing

| Activity | Useful Work? |
| --- | --- |
| Processing a batch of 4096 column values | Yes — direct computation on contiguous memory |
| SIMD: filtering 8 values in one instruction | Yes — 8x work per clock cycle |
| Memory access (columnar batches in L1/L2 cache) | Yes — cache-line aligned, minimal stalls |

## Why OS Monitoring Tools Lie

### Cache Misses
- CPU issues memory load that misses L1/L2/L3 and goes to DRAM (~100-300 cycles wait)
- CPU core is NOT retiring instructions — no useful work
- But the OS sees the core as **busy** (thread hasn't yielded, hasn't called sleep)
- `htop`, `top`, CloudWatch: reports as **CPU utilized**
- Only **hardware performance counters** (`perf stat`, Intel VTune) reveal the truth via IPC (Instructions Per Cycle)

### Branch Misprediction
- CPU predicts a branch wrong (e.g., virtual method dispatch in Spark's iterator)
- Speculatively executed 10-20 instructions down wrong path, then **flushes pipeline**
- Costs ~15-20 cycles per misprediction
- Core is technically **busy** (pipeline flush/restart are real CPU work, just wasted)
- OS monitoring: **shows as utilized**
- Hardware counters: `branch-misses` metric reveals the waste

### GC Pauses
- Different from above — **partially visible** in normal tools
- During stop-the-world GC: all application threads frozen, only GC threads run
- If executor has 4 cores and GC uses 2 threads: 2 cores busy (GC), 2 cores genuinely idle
- You can see this in: Spark UI (GC time per task), `jstat`, CPU graphs (periodic dips)
- Even GC threads hit cache-thrashing — walking object graphs scattered across heap

## What Monitoring Reveals vs. Hides

| What's Happening | OS Reports (top/CloudWatch) | Reality | How to See Truth |
| --- | --- | --- | --- |
| Productive computation | Busy | Busy | — |
| Cache miss stall (100+ cycles) | **Busy** | Stalled | `perf stat` → low IPC |
| Branch misprediction + flush | **Busy** | Wasting cycles | `perf stat` → `branch-misses` |
| GC pause (application threads) | **Idle** (visible drop) | Frozen | Spark UI GC time |
| GC pause (GC threads) | Busy | Non-productive | JVM GC logs |
| SIMD processing 8 values (Photon) | Busy | 8x productive per cycle | `perf stat` → high IPC |

## The Correct Mental Model

Both show ~85% CPU utilization. The difference:
- JVM Spark at 85% CPU → processes X million rows/second
- Photon at 85% CPU → processes 2-5X million rows/second

Like two trucks both driving at full speed (same RPM), but one carries 5 tons and the other 20 tons.

## Hardware Counter Metrics (if accessible)

- **IPC**: Photon ~2-3; JVM Spark ~0.5-1 on the same workload
- **L2 cache miss rate**: Photon ~2%; JVM scattered objects ~20%+
- **Branch miss rate**: Photon <1%; JVM virtual dispatch ~5-10%

Accessible via `perf stat -p <pid>` on Linux, but Databricks doesn't surface these in standard dashboards. Requires SSH access + root privileges, which most users don't have.

In practice, you observe Photon's benefit as "my job finished in 10 minutes instead of 35" without being able to pinpoint exactly why from CPU charts.
