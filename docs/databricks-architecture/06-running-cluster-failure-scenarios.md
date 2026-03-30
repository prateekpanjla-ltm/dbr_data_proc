# Running Cluster Failure Scenarios

## Overview

This document analyzes what happens to an **already-running** Databricks cluster when various AWS services fail, from the cluster's perspective.

## What a Running Cluster Talks To

| Dependency | Communication | Purpose |
| --- | --- | --- |
| Control plane (HTTPS/443) | Bidirectional | Notebook command dispatch, results delivery, log streaming, credential refresh, S3 commit service, secrets, library installs |
| S3 (VPC Gateway Endpoint) | Outbound | Read/write data files, Delta log, checkpoints, DBFS root |
| STS | Outbound (periodic) | Refresh temporary IAM credentials (expire every 6 hours) |
| Kinesis | Outbound | Stream cluster logs to control plane |
| KMS | Outbound (if CMK) | Decrypt/encrypt S3 objects and EBS volumes |
| Other EC2 instances | Internal VPC | Shuffle data, task dispatch, heartbeats |
| EBS volumes | Local to instance | Shuffle spill, temp storage, container root |
| NAT Gateway | Outbound | External API calls, package downloads |

---

## CONTROL PLANE UNREACHABLE

| Scenario | What Happens | Job Finishes? |
| --- | --- | --- |
| Job reading S3, transforming, writing back to S3 | Spark DAG is already compiled and executing. Data read/write goes directly to S3. Job keeps running. | **YES** — BUT Delta log commit fails if it needs the S3 commit service (multi-cluster writes). Single-cluster appends may succeed. Job status won't be reported to UI. |
| Job writing to external database (RDS, Redshift) — not S3 | Spark writes via JDBC directly from executors. Completely independent of control plane. | **YES** — Job completes fully. UI shows "running" indefinitely until connectivity restores. |
| Interactive notebook — running new cells | Each cell is dispatched from control plane to driver via HTTPS tunnel. No control plane = no new commands. | Currently running cell: **YES**. New cells: **NO** — UI shows disconnected. |
| Structured Streaming writing to Delta on S3 | Current micro-batch may complete data write, but commit fails (needs S3 commit service). Stream enters retry loop. | **NO** — Stalls at commit phase. Catches up when control plane returns. No data loss. |
| Structured Streaming writing to Kafka/database | No Delta commit involved. But checkpoint writes to S3 use the commit service. | **PARTIAL** — Data reaches sink, but checkpoints fail. On restart, some records may be reprocessed (at-least-once). |
| Job needs a Databricks secret mid-execution | Secrets fetched from control plane. If already cached at start, works. New fetch fails. | Depends on timing. If cached: **YES**. If mid-execution fetch: **FAILS**. |
| Unity Catalog credential refresh needed | UC vends short-lived credentials (~1 hour). If expired and can't refresh, S3 access fails. | **YES** if job finishes before credential expiry. **NO** if it runs longer. |
| Auto-scaling needed | Scale-up/down decisions made by Cluster Manager in control plane. Can't add/remove workers. | Job continues on current workers. May run **slower** but won't fail. |
| Library installation mid-run | Install command dispatched through control plane. | **FAILS** — Can't initiate install. |

---

## S3 UNREACHABLE (Control Plane Up)

| Scenario | What Happens | Job Finishes? |
| --- | --- | --- |
| Any job reading Delta tables | Can't read Parquet files or `_delta_log`. | **NO** — Immediate failure. |
| Pure in-memory compute writing to external DB | If data was fully loaded before S3 went down, and writes via JDBC. | **YES** — If data was cached and output is non-S3. |
| Writing to EBS local disk only | EBS is independent of S3. | **YES** — But results can't be moved to S3. |
| Structured Streaming from Kafka → Delta | Can read Kafka, can't write to S3. | **NO** — Fails at write/checkpoint step. |
| DBFS access | DBFS root backed by S3. | **NO** — All DBFS operations fail. |
| Notebook displaying pure Python results | Results go through control plane (which is up). No S3 read needed. | **YES** — For non-Spark Python cells. |

---

## STS UNREACHABLE (Credentials Can't Refresh)

| Scenario | What Happens | Job Finishes? |
| --- | --- | --- |
| Short-running job (< 1 hour) | Existing credentials valid. | **YES** |
| Long-running job (> 6 hours) | Instance profile credentials expire. S3 returns 403 Forbidden. | **NO** — Fails when credentials expire. |
| Job writing to external DB with hardcoded credentials | No STS dependency. | **YES** |

---

## EBS FAILURE

| Scenario | What Happens | Job Finishes? |
| --- | --- | --- |
| Root volume failure on driver | OS crashes. Spark driver dies. | **NO** — Catastrophic failure. |
| Root volume failure on one worker | Executor lost. Spark recomputes tasks on surviving workers. | **YES** — With delay. |
| Shuffle volume failure during heavy shuffle | Tasks on that worker fail. Spark retries on other workers, may recompute upstream stages. | **LIKELY YES** — Significantly slower. |
| Can't attach new autoscale volumes (API failure) | Existing volumes work. New writes spill to "disk full" errors. | Small jobs: **YES**. Shuffle-heavy: **NO** (DiskSpaceException). |

---

## NAT GATEWAY DOWN

| Scenario | What Happens | Job Finishes? |
| --- | --- | --- |
| Job that only reads/writes S3 | S3 traffic goes via VPC Gateway Endpoint, NOT NAT. | **YES** — No impact. |
| Job calling external REST API | External internet unreachable. API calls timeout. | **NO** — If external call is required. |
| Job writing to external DB in same VPC | Intra-VPC traffic doesn't use NAT. | **YES** — No impact. |
| Job writing to external DB over internet | Needs NAT for outbound. | **NO** — Can't reach database. |
| PyPI package install at startup | Internet access required. | **NO** — Cluster may fail to initialize. |
| Control plane connectivity (no PrivateLink) | HTTPS tunnel goes through NAT. If NAT is only path, control plane unreachable. | See control plane scenarios above. |

---

## KINESIS DOWN

| Scenario | What Happens | Job Finishes? |
| --- | --- | --- |
| Any running job | Logs stop streaming to control plane. UI shows stale/no logs. Spark job completely unaffected. | **YES** — Zero impact on execution. |

---

## KMS DOWN (Customer-Managed Keys)

| Scenario | What Happens | Job Finishes? |
| --- | --- | --- |
| Reading encrypted S3 data | S3 calls KMS to decrypt. KMS down = decryption fails. | **NO** |
| Writing to encrypted S3 | Can't encrypt new objects. | **NO** |
| Job using only unencrypted data | No KMS dependency. | **YES** |
| EBS volumes encrypted with CMK | Existing mounted volumes continue (keys cached). New volume attachments fail. | Existing work: **YES**. EBS autoscaling: **NO**. |

---

## EC2 INSTANCE FAILURES

| Scenario | What Happens | Job Finishes? |
| --- | --- | --- |
| Worker instance terminated (spot reclamation) | Executor lost. Spark recomputes tasks on surviving workers. | **YES** — Slower but resilient (Spark fault tolerance). |
| Driver instance terminated | Entire SparkContext lost. Job fails immediately. | **NO** — Never use spot for driver. |
| Multiple workers terminated simultaneously | Spark attempts to reschedule all lost tasks. If too few workers remain, tasks queue. | **MAYBE** — Depends on remaining workers and autoscaling availability. |

---

## Key Insight

A Databricks cluster is surprisingly independent once running. The Spark engine on EC2 is a self-contained distributed system. The control plane is needed for **coordination** (commands, credentials, commits, scaling) but not for **execution** of already-submitted Spark stages.

The biggest hidden dependency is **credential expiry** — everything looks fine until temporary tokens expire and suddenly S3 access stops, even though S3 itself is healthy.
