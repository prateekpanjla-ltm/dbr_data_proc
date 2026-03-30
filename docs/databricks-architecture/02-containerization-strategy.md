# Containerization Strategy: Why Containers Inside VMs

## Overview

Databricks runs Spark inside Docker containers on top of EC2 VMs rather than directly on the VM. This is a deliberate architectural choice with several compelling reasons.

## Why Not Run Directly on the VM?

### 1. Security & User Isolation (Primary Reason)
- Databricks' **Lakeguard** architecture uses container sandboxing to enforce strict boundaries
- In shared/standard compute, multiple users run workloads on the same cluster
- Containers ensure:
  - User code cannot access other users' data or the underlying host machine
  - UDFs are sandboxed — preventing file system writes or unauthorized network access
  - The Spark engine itself is isolated from user code (via Spark Connect + container boundaries)
- Running directly on the VM would mean all user code has OS-level access, making multi-tenant isolation nearly impossible

### 2. Decoupling VM Lifecycle from Spark Lifecycle
- Critical for **instance pools**
- When a cluster terminates, the EC2 instance doesn't have to be destroyed — it returns to the pool
- The container is torn down, but the VM is wiped and reused by a completely different cluster with a different Runtime version or configuration
- Without containers, you'd need to reprovision a fresh EC2 instance every time
- Pools reduce startup from ~5-10 min to ~1-2 min

### 3. Environment Reproducibility & Consistency
- The Databricks Runtime (Spark, Delta, libraries, JVM, Python) is packaged as a container image
- Guarantees identical behavior regardless of the underlying EC2 AMI or OS patches
- Different clusters can run different Runtime versions on the same pool of VMs
- **Databricks Container Services** lets you bring your own Docker image for fully locked-down "golden" environments

### 4. Runtime Injection Architecture
- Startup sequence: VM acquired → Docker image pulled → container created → Databricks Runtime code copied in → init scripts run
- This layered approach lets Databricks inject proprietary optimizations (Photon, Delta-specific code, cluster management agents) on top of any base image
- Doing this at the VM level would require custom AMIs for every Runtime version × every customization

### 5. Resource Control & Cgroup Enforcement
- Containers leverage Linux **cgroups** and **namespaces** natively
- Fine-grained control over CPU, memory, and network quotas per workload
- Essential for preventing a runaway UDF from starving the Spark driver or other executors

## Why Not Use Custom AMIs Instead of Containers?

You could bake everything into a custom Amazon Machine Image (AMI). But:

### Combinatorial Explosion
- Databricks supports dozens of Runtime versions (13.3, 14.3, 15.4, etc.) × ML vs standard × GPU vs CPU × Photon vs non-Photon
- Each combination as a separate AMI = hundreds of AMIs to build, test, maintain, and patch per region
- A container image layered on one standardized base AMI is far more manageable

### Slow to Update and Launch
- AMIs are full disk snapshots (10-30 GB), slow to create
- Launching from a fresh AMI means a full EC2 boot cycle every time
- Container images use **layered filesystems** — only changed layers are pulled, and spinning up a new container on an already-running VM takes seconds

### Instance Pools Become Impossible
- If Runtime version X is baked into the AMI, that VM can only serve clusters needing version X
- With containers, a single pooled VM running a generic base AMI can serve any Runtime version — just swap the container

### Customer Customization
- With Databricks Container Services, you bring your own Docker image and Databricks injects its Runtime code into it at startup
- With AMIs, customers would need to fork and rebuild Databricks' AMI — a security and maintenance nightmare
- Docker gives a clean contract: you own your image, Databricks owns the Runtime layer

## The Actual Architecture

- **AMI = standardized hardware abstraction** (thin OS, Docker daemon, Databricks agent)
- **Container = application-level abstraction** (Spark, Delta, libraries, your code)
- Using both together gives Databricks the best of both worlds

## Default EBS Volumes Per Instance

- 30 GB encrypted EBS instance root volume (host OS + Databricks internal services)
- 150 GB encrypted EBS container root volume (Spark worker, services, logs)
- (HIPAA only) 75 GB encrypted EBS worker log volume
