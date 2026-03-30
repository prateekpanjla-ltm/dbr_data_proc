# GH Archive Pipeline — Architecture Diagrams

_Mermaid diagrams documenting pipeline architecture, data flows, and design decisions._

---

## 1. V2 Pipeline — End-to-End Job Orchestration

```mermaid
flowchart LR
    schedule["Hourly at :00 IST"] --> Job

    subgraph Job["Scheduled Job: GH Archive V2"]
        direction LR
        subgraph T1["Task 1: ingest"]
            A1["Download .json.gz"] --> A2["latest/ to archive/"]
            A2 --> A3["Save new to latest/"]
        end
        subgraph T2["Task 2: run_pipeline"]
            B1["DLT Pipeline Update"]
        end
        T1 -->|depends_on| T2
    end
```

---

## 2. V2 DLT Pipeline — Data Flow DAG

```mermaid
flowchart TB
    subgraph Source["Volume: gharchive_dev/v2_pipeline/files"]
        VL["latest/*.json.gz"]
        VA["archive/*.json.gz"]
    end

    subgraph Pipeline["DLT Pipeline: gharchive_dev.v2_pipeline"]
        Bronze["gharchive_bronze\nStreaming Table\nspark.readStream.table"]
        Silver["gharchive_silver\nStreaming Table\nspark.readStream.table(bronze)"]
        Gold1["gold_activity_counts\nMaterialized View\nGROUP BY event_hour, type"]
        Gold2["gold_top_repos\nMaterialized View\nGROUP BY repo_name"]
        Gold3["gold_top_actors\nMaterialized View\nGROUP BY actor_login"]
    end

    VL --> Bronze
    Bronze -->|"streaming (append)"| Silver
    Silver -->|"batch (full scan)"| Gold1
    Silver -->|"batch (full scan)"| Gold2
    Silver -->|"batch (full scan)"| Gold3

    style Bronze fill:#cd7f32,color:#fff
    style Silver fill:#c0c0c0,color:#000
    style Gold1 fill:#ffd700,color:#000
    style Gold2 fill:#ffd700,color:#000
    style Gold3 fill:#ffd700,color:#000
```

---

## 3. V3 Auto Loader Pipeline — Data Flow DAG

```mermaid
flowchart TB
    subgraph Source["Volume: gharchive_dev/raw/files"]
        VF["*.json.gz (flat directory)"]
    end

    subgraph Pipeline["DLT Pipeline: gharchive_dev.v3_autoloader"]
        Bronze["gharchive_bronze\nStreaming Table\ncloudFiles (Auto Loader)"]
        Silver["gharchive_silver\nStreaming Table\ndp.read(bronze)"]
        Gold1["gold_activity_counts\n@dp.table\ndp.read(silver)"]
        Gold2["gold_top_repos\n@dp.table\ndp.read(silver)"]
        Gold3["gold_top_actors\n@dp.table\ndp.read(silver)"]
    end

    VF -->|"Auto Loader checkpoint\ntracks processed files"| Bronze
    Bronze -->|streaming| Silver
    Silver --> Gold1
    Silver --> Gold2
    Silver --> Gold3

    style Bronze fill:#cd7f32,color:#fff
    style Silver fill:#c0c0c0,color:#000
    style Gold1 fill:#ffd700,color:#000
    style Gold2 fill:#ffd700,color:#000
    style Gold3 fill:#ffd700,color:#000
```

---

## 4. V2 vs V3 — Side-by-Side Comparison

```mermaid
flowchart LR
    subgraph V2["V2 Pipeline"]
        direction TB
        V2I["ingest.py\nManages latest/ and archive/"] --> V2B["Bronze\nspark.readStream.table()"]
        V2B --> V2S["Silver\nspark.readStream.table(bronze)"]
        V2S --> V2G["Gold (3x)\n@dp.materialized_view\nspark.read.table(silver)"]
    end

    subgraph V3["V3 Auto Loader"]
        direction TB
        V3I["ingest.py\nFlat dir, skip existing"] --> V3B["Bronze\ncloudFiles (Auto Loader)"]
        V3B --> V3S["Silver\ndp.read(bronze)"]
        V3S --> V3G["Gold (3x)\n@dp.table\ndp.read(silver)"]
    end

    style V2 fill:#f0f0ff,stroke:#666
    style V3 fill:#f0fff0,stroke:#666
```

---

## 5. Incident: Silver Checkpoint Mismatch — What Happened

```mermaid
sequenceDiagram
    participant Ingest as Ingest Task
    participant Bronze as gharchive_bronze
    participant Silver as gharchive_silver
    participant Checkpoint as Silver Checkpoint

    Note over Bronze: Original table ID: be8e2694

    Ingest->>Bronze: Write data (normal)
    Bronze->>Silver: Stream records
    Silver->>Checkpoint: Store source table ID: be8e2694

    Note over Bronze: ⚠️ Table DROPPED and RECREATED
    Note over Bronze: New table ID: 3b8d78cb

    Ingest->>Bronze: Write data to new table
    Bronze->>Silver: Attempt to stream
    Checkpoint-->>Silver: ❌ Expected ID be8e2694 but got 3b8d78cb

    Note over Silver: DIFFERENT_DELTA_TABLE_READ_BY_STREAMING_SOURCE

    Note over Silver: 🔧 FIX: Full refresh silver
    Silver->>Checkpoint: Clear old checkpoint
    Silver->>Checkpoint: Store new source ID: 3b8d78cb
    Bronze->>Silver: ✅ Stream resumes successfully
```

---

## 6. DLT Refresh Types — Decision Flow

```mermaid
flowchart TD
    Start["Pipeline table needs refresh"] --> Q1{"What type\nof table?"}

    Q1 -->|Streaming Table| Q2{"What's the\nproblem?"}
    Q1 -->|Materialized View| MV["Default Refresh\n(auto-recomputes\nfrom source)"]

    Q2 -->|"New data to process"| DR["Default Refresh\nProcess only new\nrecords via checkpoint"]
    Q2 -->|"Checkpoint corrupted\nor source table recreated"| FR["Full Refresh\nClear checkpoint + data\nReprocess everything"]
    Q2 -->|"Want to reprocess\nbut keep existing data"| RC["Reset Checkpoints\nClear checkpoint only\nKeep data, reprocess all"]

    DR --> Done["✅ Update complete"]
    FR --> Done
    RC --> Done
    MV --> Done

    style FR fill:#ff6b6b,color:#fff
    style DR fill:#69db7c,color:#000
    style RC fill:#ffd43b,color:#000
    style MV fill:#74c0fc,color:#000
```

---

## 7. Medallion Architecture — Streaming vs Batch Decision Tree

```mermaid
flowchart TD
    Start["Gold layer aggregation"] --> Q1{"Is the aggregation\ncommutative?"}

    Q1 -->|"Yes: count, sum,\nmin, max, avg"| Stream["✅ Can use\nStreaming Table\n(incremental)"]
    Q1 -->|"No: countDistinct,\npercentile, ranking"| Q2{"Data volume?"}

    Q2 -->|"Small/Medium\n(recompute is cheap)"| MV["✅ Use\nMaterialized View\n(full recompute)"]
    Q2 -->|"Very Large\n(recompute expensive)"| Dedup["⚙️ Dedup Pattern:\n1. Streaming dedup table\n2. Simple count over it"]

    Stream --> Note1["Examples:\nHourly event counts\nRunning totals\nMin/max timestamps"]
    MV --> Note2["Examples:\nTop repos by events\nUnique actors per repo\nActivity rankings"]
    Dedup --> Note3["Tradeoff:\nMore storage + complexity\nBut avoids full rescans"]

    style Stream fill:#69db7c,color:#000
    style MV fill:#74c0fc,color:#000
    style Dedup fill:#ffd43b,color:#000
```

---

## 8. Project File Structure

```mermaid
graph TB
    subgraph Root["dbr_data_proc/"]
        YML["databricks.yml"]
        LEARN["LEARNINGS.md"]
        ARCH["ARCHITECTURE.md"]

        subgraph GH[".github/workflows/"]
            GH1["dabs-deploy.yml"]
            GH2["infra-deploy.yml"]
        end

        subgraph Infra["infra/"]
            TF1["main.tf"]
            TF2["variables.tf"]
            SQL1["bootstrap.sql"]
            SQL2["setup-dev.sql"]
        end

        subgraph Src["src/"]
            subgraph V2["v2_pipeline/"]
                V2I["ingest.py"]
                V2B["bronze/"]
                V2S["silver/"]
                V2G["gold/"]
            end
            subgraph V3["v3_autoloader/"]
                V3I["ingest.py"]
                V3P["pipeline (notebook)"]
            end
        end
    end

    style V2 fill:#f0f0ff,stroke:#666
    style V3 fill:#f0fff0,stroke:#666
    style Infra fill:#fff0f0,stroke:#666
    style GH fill:#fffff0,stroke:#666
```

---

## 9. Data Lineage — Volume to Gold

```mermaid
flowchart LR
    subgraph External["External Source"]
        GHA["data.gharchive.org\nHourly JSON dumps"]
    end

    subgraph Ingest["Ingest Task"]
        DL["Download\n.json.gz files"]
    end

    subgraph Storage["Unity Catalog Volumes"]
        V2Vol["v2: latest/ + archive/"]
        V3Vol["v3: flat directory"]
    end

    subgraph Bronze["Bronze Layer"]
        B2["v2: readStream.table"]
        B3["v3: cloudFiles"]
    end

    subgraph Silver["Silver Layer"]
        S["Flatten structs\nExplode commits\nParse timestamps\nExtract payload fields"]
    end

    subgraph Gold["Gold Layer"]
        G1["Activity Counts\nby hour + event type"]
        G2["Top Repos\nby event count"]
        G3["Top Actors\nby contribution count"]
    end

    GHA --> DL
    DL --> V2Vol
    DL --> V3Vol
    V2Vol --> B2
    V3Vol --> B3
    B2 --> S
    B3 --> S
    S --> G1
    S --> G2
    S --> G3
```
