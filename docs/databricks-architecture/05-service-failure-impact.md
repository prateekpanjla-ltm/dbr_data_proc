# AWS Service Failure Impact Analysis

## Overview

This document analyzes the impact of various AWS service failures on the Databricks platform, split by whether fallback options exist.

## Impact Classification (Split by Fallback Availability)

### EC2

| Scenario | Fallback? | Impact |
| --- | --- | --- |
| Regional EC2 outage | No (unless DR region configured) | **CRITICAL** — No compute whatsoever |
| Single-AZ failure | Yes — clusters reschedule to other AZ subnets | **MODERATE** — Temporary disruption, auto-recovery |
| Spot capacity unavailable | Yes — falls back to on-demand instances | **MINIMAL** — Higher cost, no functional impact |
| Spot reclamation (instances taken back) | Yes — Spark re-executes lost tasks on remaining/new nodes | **MINIMAL** — Job slowdown, not failure (unless driver is spot) |

### S3

| Scenario | Fallback? | Impact |
| --- | --- | --- |
| Regional S3 outage | No | **CRITICAL** — All data inaccessible, all writes fail |
| Throttling (503 SlowDown) | Yes — Spark retries with exponential backoff | **MODERATE** — Jobs slow down but eventually succeed |

### IAM / STS

| Scenario | Fallback? | Impact |
| --- | --- | --- |
| STS outage | Partial — existing temporary credentials valid up to 6 hours | **CRITICAL (delayed)** — Existing clusters survive short-term; no new clusters can start |

### EBS

| Scenario | Fallback? | Impact |
| --- | --- | --- |
| Can't create new volumes | Partial — existing attached volumes still work | **SEVERE** for new clusters (can't boot); **MODERATE** for running clusters (no autoscale but current disk works) |
| Single volume failure | Yes — EBS replicates within AZ | **MINIMAL** — Rare occurrence |

### NAT Gateway

| Scenario | Fallback? | Impact |
| --- | --- | --- |
| NAT in one AZ fails | Yes — if NAT deployed in multiple AZs, traffic routes through surviving NAT | **MINIMAL** — Brief rerouting |
| All NATs fail / single-AZ NAT | No fallback for outbound internet | **SEVERE** — No package installs, no external APIs. S3 still works via VPC Gateway Endpoint. Clusters keep running for S3-only workloads |
| NAT fails and it's the only path to control plane (no PrivateLink) | No | **CRITICAL** — Control plane unreachable, see control plane scenarios |

### PrivateLink

| Scenario | Fallback? | Impact |
| --- | --- | --- |
| PrivateLink endpoint fails + **public fallback allowed** | Yes — traffic falls back to public HTTPS via NAT | **MINIMAL** — Seamless failover |
| PrivateLink endpoint fails + **public access disabled** (strict private-only config) | No | **CRITICAL** — Clusters cannot reach control plane. No commands execute, no logs flow, no job scheduling. Equivalent to total platform outage |

### KMS

| Scenario | Fallback? | Impact |
| --- | --- | --- |
| KMS outage + **customer-managed keys enabled** | No — decryption impossible | **CRITICAL** — All encrypted data unreadable, new encrypted volumes can't be created |
| KMS outage + **AWS-managed keys or no encryption** | Not applicable | **NONE** — No impact |

### Kinesis

| Scenario | Fallback? | Impact |
| --- | --- | --- |
| Kinesis outage | Partial — clusters buffer logs locally | **MINIMAL** — Clusters keep running. Log viewing in UI breaks. Logs may be lost if buffer fills |

### SQS / SNS

| Scenario | Fallback? | Impact |
| --- | --- | --- |
| SQS outage | Partial — Auto Loader can fall back to **directory listing mode** | **MODERATE** — Streaming ingestion slows (O(files) not O(new files)), but doesn't stop |
| SNS outage | Partial — existing SQS messages still process; new file notifications stop | **MODERATE** — Temporary ingestion lag, catches up on recovery |

### CloudTrail

| Scenario | Fallback? | Impact |
| --- | --- | --- |
| CloudTrail outage | No fallback (audit gap) | **MINIMAL** — Zero operational impact. Compliance/audit logging paused |

### CloudWatch

| Scenario | Fallback? | Impact |
| --- | --- | --- |
| CloudWatch outage | No fallback for external monitoring | **MINIMAL** — Databricks internal monitoring unaffected. Only external dashboards go dark |

### Spot Instance Service

| Scenario | Fallback? | Impact |
| --- | --- | --- |
| Spot service unavailable | Yes — fall back to on-demand (if configured) | **MINIMAL** — Higher cost |
| Spot-only configured, no on-demand fallback | No | **SEVERE** — Clusters can't acquire workers |

## Key Takeaway

The **strictness of your security configuration** directly determines whether a service failure is survivable:
- PrivateLink-only = no public fallback path
- Customer-managed KMS = data inaccessible if KMS fails
- Spot-only clusters = no compute if spot unavailable
- Single-AZ NAT = internet outage for the entire workspace

S3 and EC2 are the two true single points of failure — a full regional outage of either is unrecoverable for any workload in that region.
