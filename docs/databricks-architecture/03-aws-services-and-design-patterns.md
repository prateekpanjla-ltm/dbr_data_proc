# AWS Services Integration and Design Patterns

## AWS Services Used by Databricks

| AWS Service | Role |
| --- | --- |
| **EC2** | Compute instances (driver + workers), spot and on-demand |
| **EBS** | Local storage, shuffle volumes, container root, OS root. Auto-scales by hot-attaching new GP3 volumes |
| **S3** | Primary data lake storage (Delta tables, Unity Catalog managed storage, DBFS root, checkpoints, logs, artifacts) |
| **VPC / Subnets / Security Groups** | Network isolation — private subnets across AZs, security groups for inter-node traffic |
| **NAT Gateway** | Outbound internet access from private subnets (package installs, external APIs) |
| **IAM / STS** | Cross-account role assumption, instance profiles for fine-grained S3 access, service credentials |
| **KMS** | Customer-managed encryption keys for workspace storage (S3), EBS volumes, and managed tables |
| **SQS** | Auto Loader file notification mode — receives S3 event notifications for incremental ingestion |
| **SNS** | Auto Loader — creates topics that subscribe to S3 bucket events and fan out to SQS queues |
| **Kinesis** | Log streaming from the compute plane back to the Databricks control plane for monitoring |
| **PrivateLink** | Private connectivity to control plane and AWS services (eliminates public internet traversal) |
| **CloudTrail** | Audit logging — tracks API calls and access patterns for compliance |
| **CloudWatch** | Optional — forward cluster logs and metrics for centralized monitoring |

## AWS-Specific Design Patterns

### Networking
- Deploy workspaces in a **customer-managed VPC** with private subnets across multiple AZs
- Enable **Secure Cluster Connectivity (SCC)** — no public IPs on cluster nodes, all traffic tunneled over HTTPS/443
- Use **AWS PrivateLink** for private control plane access
- Use **S3 Gateway VPC Endpoints** for free, private S3 access
- Interface VPC endpoints for **STS** and **Kinesis** to keep all traffic off the public internet
- Configure NAT Gateways in multiple AZs for high availability
- Implement network segmentation: separate VPCs or subnets for dev/test/prod environments

### Compute
- Use **instance pools** to pre-warm EC2 instances and reduce startup latency
- Spot instances for dev/test and fault-tolerant batch jobs; on-demand for production-critical workloads
- Separate driver (on-demand) and worker (spot) pools
- For shuffle-heavy workloads, use NVMe-equipped instances (i3, m5d, c5d, r6id families)

### Security
- **Customer-managed KMS keys** for encrypting S3 workspace storage and EBS volumes
- Scoped **IAM instance profiles** per cluster for least-privilege S3 access
- Unity Catalog **storage credentials** (IAM roles) for governed access to external locations
- Enable Secure Cluster Connectivity to eliminate inbound open ports

### Infrastructure as Code
- **Terraform** (Databricks provider) for workspace, network, Unity Catalog, and cluster policy automation
- **Databricks Asset Bundles** for deploying jobs, pipelines, and notebooks across environments

### Storage
- Unity Catalog managed storage at catalog level as primary unit of data isolation
- Do not use workspace root bucket (DBFS) for production customer data
- Use Unity Catalog external locations to override default workspace storage
- Configure S3 lifecycle policies for cost management

## EBS Auto-Scaling: How It Works

Databricks does NOT resize existing EBS volumes. Instead:

1. Monitors free disk space on each Spark worker node
2. When a worker runs low on disk, calls `ec2:CreateVolume` + `ec2:AttachVolume`
3. Hot-attaches a **new GP3 EBS volume** to the running EC2 instance
4. OS detects the new block device, mounts it, Spark uses the extra space
5. Continues up to **5 TB total limit** per instance
6. Volumes are **never detached** while the instance is running
7. Cleaned up only when the instance is terminated or returned to pool

This is like plugging in extra USB drives to a running laptop, not stretching an existing drive.

### Required IAM Permissions for EBS Auto-Scaling
- `ec2:CreateVolume`
- `ec2:AttachVolume`
- `ec2:DeleteVolume`
- `ec2:DescribeVolumes`

## Network Bandwidth and Instance Size Correlation

AWS ties network bandwidth directly to instance size:

| Instance | Network Bandwidth | Typical Use |
| --- | --- | --- |
| `m5.large` | Up to 10 Gbps (burstable) | Light ETL, dev/test |
| `m5.24xlarge` | 25 Gbps | Heavy workloads |
| `i3.xlarge` | Up to 10 Gbps | Caching, shuffle-heavy |
| `i3.16xlarge` | 25 Gbps | Large shuffle + cache |
| `c5n.18xlarge` | 100 Gbps | Network-bound workloads |

Small instances get burstable network — once burst credits are exhausted, you're throttled. For sustained S3-heavy workloads, this ceiling is hit fast.

## Data Flow Architecture: What Goes Where

```
EC2 Instance (Worker)
├── Spark Executor (in memory) ──────────────→ S3 (via VPC Gateway Endpoint)
├── Disk Cache (local SSD/EBS) ─ cache hit ─→ No network call!
└── Shuffle / Spill (local NVMe/EBS) ──────→ Stays local, never goes to S3
```

Design philosophy: **Read from S3 once, cache locally, shuffle locally, write back to S3 in optimized batches.**
