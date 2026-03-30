# Cluster Startup and Architecture on AWS

## Overview

When a Databricks cluster spins up (via a scheduled job, notebook attach, or manual start), a multi-step orchestration takes place between the Databricks control plane and various AWS services in your account.

## Control Plane vs Compute Plane

### Control Plane (Databricks' AWS Account)
- Backend services managed by Databricks
- Hosts: Web application/UI, Cluster Manager, Job Scheduler, S3 Commit Service, Notebook command dispatch
- Located in Databricks' own AWS account, NOT your account

### Classic Compute Plane (Your AWS Account)
- Where your data is actually processed
- EC2 instances, VPC, subnets, EBS volumes — all in your AWS account
- Same AWS region as your workspace

### Serverless Compute Plane (Databricks' Account)
- Managed entirely by Databricks
- Same region as your workspace
- Network boundary isolation per workspace

## Cluster Startup Sequence

### Step 1: Request Initiation
When you run a notebook or a scheduled job triggers, the request hits the **Cluster Manager** service in the control plane with your cluster specifications (node type, worker count, Runtime version, Spark config, etc.).

### Step 2: Cross-Account Authentication (IAM + STS)
- Databricks uses a **cross-account IAM role** configured during workspace setup
- The control plane calls **AWS STS (Security Token Service)** to assume this role
- Obtains temporary credentials to provision resources in your AWS account
- This is the trust bridge between Databricks' account and yours

### Step 3: EC2 Instance Provisioning
Using the assumed role, the Cluster Manager calls AWS EC2 APIs:

| Action | AWS API | Purpose |
| --- | --- | --- |
| Launch instances | `ec2:RunInstances` / `ec2:CreateFleet` | Provisions driver + worker EC2 instances |
| Create launch templates | `ec2:CreateLaunchTemplate` | Defines instance config for fleet-based launches |
| Attach EBS volumes | `ec2:CreateVolume` / `ec2:AttachVolume` | Storage for shuffle data, spill, and local temp data |
| Assign IPs | `ec2:AssignPrivateIpAddresses` | Each node gets 2 private IPs (management + Spark container) |
| Configure security groups | `ec2:AuthorizeSecurityGroupIngress/Egress` | Controls traffic between driver, workers, and control plane |
| Tag resources | `ec2:CreateTags` | Tags instances for cost tracking and management |

Instances launch into **private subnets** across multiple availability zones in your workspace VPC.

### Step 4: Networking Setup
- **Secure Cluster Connectivity (SCC):** Enabled by default — cluster nodes have no public IPs. Nodes establish an outbound HTTPS tunnel (port 443) to the control plane via a secure relay.
- **NAT Gateway:** Provides outbound internet access from private subnets.
- **S3 Gateway VPC Endpoint:** Free, private path to S3 without traversing the internet.
- **Interface VPC Endpoints (PrivateLink):** For private access to AWS STS and Kinesis services.

### Step 5: Container & Runtime Bootstrap
1. VMs are acquired from the cloud provider
2. The **Databricks Runtime image** (Spark, Delta Lake, libraries, optimizations) is loaded
3. A **Docker container** is created from the image
4. **Databricks Runtime code** is copied into the container
5. **Init scripts** execute (if configured)
6. The **Spark driver** starts on the driver node; **Spark executors** start on worker nodes and register back with the driver

### Step 6: Control Plane Communication Established
- Cluster nodes send log streams and metrics back via **AWS Kinesis**
- The secure HTTPS/443 tunnel carries orchestration commands, status heartbeats, and notebook command execution
- The web app can now route notebook commands to the running Spark driver

## Cluster Types

- **All-purpose clusters**: Created via UI/CLI/API, manually managed, shared for interactive analysis
- **Job clusters**: Created automatically by the job scheduler, terminated when the job completes, cannot be restarted

## Typical Startup Times
- Classic compute: ~5-10 minutes
- With instance pools: ~1-2 minutes (VMs pre-warmed)
- Serverless compute: seconds (managed by Databricks)
