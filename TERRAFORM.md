# Terraform + Databricks Asset Bundle Deployment Plan

_Infrastructure-as-Code strategy for GH Archive pipelines (2026-03-26)_

---

## 1. Architecture Overview

```
GitHub Repository
├── .github/workflows/
│   └── deploy.yml                  # GitHub Actions workflow
├── terraform/
│   ├── main.tf                     # Provider config, backend
│   ├── variables.tf                # Input variables (prefix, SP name, etc.)
│   ├── terraform.tfvars            # Environment-specific values
│   ├── service_principal.tf        # SP creation + permissions
│   ├── unity_catalog.tf            # Catalog, schemas, volumes
│   ├── workspace.tf                # Workspace creation (optional)
│   ├── verification.tf             # Post-deploy checks
│   └── outputs.tf                  # Outputs for DAB consumption
├── bundle/
│   ├── databricks.yml              # DAB root config
│   ├── resources/
│   │   ├── v1_pyspark_job.yml      # V1 job definition
│   │   ├── v2_pipeline.yml         # V2 pipeline + job
│   │   └── v3_autoloader.yml       # V3 pipeline + job
│   └── src/
│       ├── ingest/                 # Shared ingest notebooks
│       ├── v1_pyspark/             # V1 notebooks
│       ├── v2_pipeline/            # V2 pipeline code
│       └── v3_autoloader/          # V3 pipeline code
└── README.md
```

### Two-Phase Deployment

```
Phase 1: Terraform                    Phase 2: Databricks Asset Bundle
─────────────────────                 ──────────────────────────────────
Service Principal    ──┐              
Catalog + Schemas    ──┤              Jobs
Volumes              ──┼── outputs ──> Pipelines
Permissions/Grants   ──┤              Notebooks/Code
Verification Checks  ──┘              Schedules
```

Terraform provisions the infrastructure (catalog, schemas, volumes, permissions).
DAB deploys the code and orchestration (pipelines, jobs, notebooks).
Clean separation: Terraform owns state, DAB owns code.

---

## 2. Parameterization Strategy

### Recommendation: Prefix at CATALOG Level

```
gharchive_{prefix}        <-- Catalog (e.g., gharchive_test, gharchive_dev, gharchive_prod)
├── v1_pyspark            <-- Schema (unchanged across environments)
│   ├── gharchive_bronze
│   ├── gharchive_silver
│   └── gharchive_gold_*
├── v2_pipeline           <-- Schema
│   └── ...
└── v3_autoloader         <-- Schema
    └── ...
```

**Why catalog-level, not schema or table:**

| Level | Example | Pros | Cons |
|---|---|---|---|
| Catalog | gharchive_test.v1_pyspark.gharchive_bronze | Full isolation, clean RBAC, no code changes to schema/table refs | Need catalog-level permissions |
| Schema | gharchive_dev.test_v1_pyspark.gharchive_bronze | Moderate isolation | Every schema reference in code must be parameterized |
| Table | gharchive_dev.v1_pyspark.test_gharchive_bronze | Fine-grained | Every table reference in code changes, fragile, error-prone |

Catalog-level is cleanest because:
- Schema names and table names stay identical across environments
- Pipeline code references gharchive_silver (not test_gharchive_silver)
- RBAC is natural: grant on catalog = grant on everything inside
- Full environment isolation: test catalog can be dropped without affecting dev/prod
- DAB catalog variable naturally maps to this

### Variable Mapping

```hcl
variable "environment_prefix" {
  description = "Environment prefix: test, dev, staging, prod"
  type        = string
  default     = "dev"
}

locals {
  catalog_name = "gharchive_${var.environment_prefix}"
  schemas      = ["v1_pyspark", "v2_pipeline", "v3_autoloader"]
}
```

---

## 3. Service Principal Strategy

### 3.0 Deployer vs Runner — NOT Job vs Code

Databricks does NOT recommend separate SPs for "executing jobs" vs "executing code" —
they are the same thing. A job IS code execution. When a job runs, it executes
notebooks/scripts/pipelines on compute. The `run_as` principal is the identity for
both the job trigger and the code inside it.

The recommended separation is:

| SP | Purpose | Why separate |
|---|---|---|
| Deployer SP | Provisions infrastructure, deploys code (Terraform + DAB) | Broad CREATE/MANAGE permissions, used only in CI/CD |
| Runtime SP | Runs jobs, pipelines, code | Narrower data access permissions (SELECT, MODIFY, READ/WRITE_VOLUME) |

This is a **deployer vs runner** split, not a job vs code split.
The runner SP is the same identity whether it's executing a job, running a
notebook inside that job, or owning a DLT pipeline.

### 3.1 Provisioner Service Principal (runs Terraform + DAB)

This SP is the "deployer" — it runs in GitHub Actions and provisions everything.

```hcl
# service_principal.tf

# Option A: Reuse existing SP by name
data "databricks_service_principal" "deployer" {
  count        = var.create_service_principal ? 0 : 1
  display_name = var.deployer_sp_name
}

# Option B: Create new SP
resource "databricks_service_principal" "deployer" {
  count        = var.create_service_principal ? 1 : 0
  display_name = var.deployer_sp_name
}

locals {
  deployer_sp_id = var.create_service_principal ? databricks_service_principal.deployer[0].application_id : data.databricks_service_principal.deployer[0].application_id
}
```

**Required permissions for the deployer SP:**
- Account admin (if creating workspaces)
- Workspace admin (if creating catalogs)
- CREATE CATALOG on metastore
- CREATE SCHEMA on catalog
- CREATE TABLE on schema
- CREATE VOLUME on schema
- MANAGE on all resources it creates

### 3.2 Runtime Service Principal (runs pipelines/jobs)

This SP is the "runner" — it executes the actual pipelines and jobs.

```hcl
variable "runtime_sp_name" {
  description = "Service principal name that will run all pipelines and jobs"
  type        = string
}

data "databricks_service_principal" "runtime" {
  display_name = var.runtime_sp_name
}

# Grant runtime SP permissions on catalog
resource "databricks_grants" "catalog_grants" {
  catalog = databricks_catalog.main.name

  grant {
    principal  = data.databricks_service_principal.runtime.application_id
    privileges = [
      "USE_CATALOG",
      "USE_SCHEMA",
      "SELECT",
      "MODIFY",
      "CREATE_TABLE",
      "CREATE_MATERIALIZED_VIEW",   # Required for V2/V3 gold MVs and V3 silver MV
      "CREATE_FUNCTION",
      "READ_VOLUME",
      "WRITE_VOLUME"
    ]
  }
}

# Grant on each schema
resource "databricks_grants" "schema_grants" {
  for_each = toset(local.schemas)
  schema   = "${databricks_catalog.main.name}.${each.value}"

  grant {
    principal  = data.databricks_service_principal.runtime.application_id
    privileges = [
      "USE_SCHEMA",
      "SELECT",
      "MODIFY",
      "CREATE_TABLE",
      "CREATE_MATERIALIZED_VIEW",   # Required for V2/V3 gold MVs and V3 silver MV
      "CREATE_FUNCTION",
      "READ_VOLUME",
      "WRITE_VOLUME"
    ]
  }

  depends_on = [databricks_schema.schemas]
}

# Grant workspace-level permissions for deployed code files
# DAB deploys notebooks under its root_path; the runtime SP needs CAN_READ
# on that folder. DAB handles this automatically when run_as is configured,
# but if notebooks are in a shared workspace path, add:
resource "databricks_permissions" "bundle_folder" {
  directory_path = "/Workspace/Users/${data.databricks_service_principal.runtime.application_id}/.bundle"

  access_control {
    service_principal_name = data.databricks_service_principal.runtime.application_id
    permission_level       = "CAN_READ"
  }
}
```

### 3.3 Permissions Gap Analysis (from pipeline code review)

Each pipeline was reviewed for operations that require specific grants:

#### V1 — PySpark Notebooks + Job

| Operation | Code | Permission | Covered? |
|---|---|---|---|
| Download files to volume | `open(dest, "wb")` | WRITE_VOLUME | Yes |
| Check file existence | `dbutils.fs.ls(volume_dest)` | READ_VOLUME | Yes |
| Check table existence | `spark.catalog.tableExists()` | USE_SCHEMA | Yes |
| Read tables | `spark.read.table(BRONZE_TABLE)` | SELECT | Yes |
| Append to Delta table | `.write.mode("append").saveAsTable()` | MODIFY + CREATE_TABLE | Yes |
| Overwrite Delta table | `.write.mode("overwrite").saveAsTable()` | MODIFY + CREATE_TABLE | Yes |
| Pass task values | `dbutils.jobs.taskValues.set()` | No grant needed (job API) | Yes |
| Widget parameters | `dbutils.widgets.text()` | No grant needed (runtime API) | Yes |

#### V2 — DLT Pipeline (Streaming Tables + Materialized Views)

| Operation | Code | Permission | Covered? |
|---|---|---|---|
| Download files to volume | `open(dest, "wb")` | WRITE_VOLUME | Yes |
| Move files in volume | `dbutils.fs.mv()` | WRITE_VOLUME | Yes |
| Create streaming tables | `@dp.table` (bronze, silver) | CREATE_TABLE | Yes |
| Create materialized views | `@dp.materialized_view` (gold) | **CREATE_MATERIALIZED_VIEW** | **Added above** |
| DLT pipeline ownership | `run_as` in DAB config | **CAN_MANAGE on pipeline** | **DAB handles via run_as** |
| Read workspace notebooks | Pipeline reads source code | **CAN_READ on folder** | **DAB handles via deploy** |

#### V3 — Auto Loader Pipeline (cloudFiles + Materialized Views)

| Operation | Code | Permission | Covered? |
|---|---|---|---|
| Download files to volume | `open(dest, "wb")` | WRITE_VOLUME | Yes |
| Auto Loader file discovery | `cloudFiles` on volume path | READ_VOLUME | Yes |
| Create streaming table | `@dp.table` (bronze) | CREATE_TABLE | Yes |
| Create materialized views | `@dp.table` with `dp.read()` (silver, gold) | **CREATE_MATERIALIZED_VIEW** | **Added above** |
| DLT pipeline ownership | `run_as` in DAB config | **CAN_MANAGE on pipeline** | **DAB handles via run_as** |
| Read workspace notebooks | Pipeline reads source code | **CAN_READ on folder** | **DAB handles via deploy** |

#### Summary of Changes Made

| Permission | Was Missing? | Where Added | Why |
|---|---|---|---|
| CREATE_MATERIALIZED_VIEW | Yes | catalog_grants + schema_grants | V2 gold MVs, V3 silver + gold MVs. CREATE_TABLE does NOT cover MVs. |
| CAN_MANAGE on pipeline | Yes (workspace-level) | Not in Terraform — handled by DAB `run_as` config | Pipeline resource permission, not UC grant |
| CAN_READ on workspace folder | Yes (workspace-level) | Not in Terraform — handled by DAB deployment | Code deployed under SP's bundle root |

---

## 4. Terraform Resources

### 4.1 Workspace (Optional — Account-Level)

Workspace creation requires account-level provider and AWS infrastructure.

```hcl
# workspace.tf — Only if creating a new workspace

# This requires:
# - Account-level Databricks provider (not workspace-level)
# - AWS provider for S3 bucket, IAM roles, VPC
# - databricks_mws_workspaces resource

# RECOMMENDATION: Skip workspace creation in Terraform.
# Workspaces are long-lived, rarely provisioned, and require
# significant AWS infrastructure (VPC, NAT, S3, IAM cross-account trust).
# Create workspace manually or via separate account-level Terraform config.
# This config assumes workspace already exists.

variable "databricks_host" {
  description = "Existing Databricks workspace URL"
  type        = string
}
```

**Why skip workspace creation here:**
- Workspace creation needs account-level admin + AWS infrastructure
- It's a one-time operation, not per-environment
- Mixing account-level and workspace-level providers in one config is complex
- Better as a separate Terraform module maintained by platform team

### 4.2 Unity Catalog Resources

```hcl
# unity_catalog.tf

resource "databricks_catalog" "main" {
  name    = local.catalog_name
  comment = "GH Archive pipeline data - ${var.environment_prefix} environment"

  properties = {
    environment = var.environment_prefix
    managed_by  = "terraform"
    project     = "gharchive"
  }
}

resource "databricks_schema" "schemas" {
  for_each     = toset(local.schemas)
  catalog_name = databricks_catalog.main.name
  name         = each.value
  comment      = "GH Archive ${each.value} schema - ${var.environment_prefix}"

  properties = {
    environment = var.environment_prefix
    managed_by  = "terraform"
  }
}

# Volume for raw data ingestion (one per pipeline version)
resource "databricks_volume" "raw_files" {
  for_each     = toset(local.schemas)
  catalog_name = databricks_catalog.main.name
  schema_name  = each.value
  name         = "raw_files"
  volume_type  = "MANAGED"
  comment      = "Raw GH Archive JSON files for ${each.value}"
}
```

### 4.3 Variables File

```hcl
# variables.tf

variable "environment_prefix" {
  description = "Environment prefix: test, dev, staging, prod"
  type        = string
  validation {
    condition     = contains(["test", "dev", "staging", "prod"], var.environment_prefix)
    error_message = "environment_prefix must be one of: test, dev, staging, prod"
  }
}

variable "databricks_host" {
  description = "Databricks workspace URL"
  type        = string
}

variable "deployer_sp_name" {
  description = "Display name of the SP used for deployment"
  type        = string
  default     = "gharchive-deployer"
}

variable "runtime_sp_name" {
  description = "Display name of the SP that runs pipelines/jobs"
  type        = string
}

variable "create_service_principal" {
  description = "Whether to create a new deployer SP or reuse existing"
  type        = bool
  default     = false
}
```

---

## 5. Verification Checks

After Terraform apply, verify the environment before deploying code.

```hcl
# verification.tf

data "databricks_catalog" "verify" {
  name       = databricks_catalog.main.name
  depends_on = [databricks_catalog.main]
}

data "databricks_schema" "verify" {
  for_each   = toset(local.schemas)
  name       = "${databricks_catalog.main.name}.${each.value}"
  depends_on = [databricks_schema.schemas]
}

resource "null_resource" "verify_environment" {
  depends_on = [
    databricks_catalog.main,
    databricks_schema.schemas,
    databricks_volume.raw_files,
    databricks_grants.catalog_grants,
    databricks_grants.schema_grants,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      echo "=== Environment Verification ==="
      echo "Catalog: ${databricks_catalog.main.name}"
      echo "Schemas: ${join(", ", [for s in databricks_schema.schemas : s.name])}"
      echo "Runtime SP: ${var.runtime_sp_name}"
      databricks catalogs get ${databricks_catalog.main.name}
      databricks schemas list ${databricks_catalog.main.name}
      echo "=== Verification Complete ==="
    EOT
  }
}
```

### Additional Verification in GitHub Actions (post-Terraform, pre-DAB)

```yaml
- name: Verify environment
  run: |
    CATALOG="gharchive_${{ inputs.environment }}"
    echo "Verifying catalog: $CATALOG"
    databricks catalogs get $CATALOG
    
    for schema in v1_pyspark v2_pipeline v3_autoloader; do
      echo "Verifying schema: $CATALOG.$schema"
      databricks schemas get $CATALOG.$schema
    done
    
    for schema in v1_pyspark v2_pipeline v3_autoloader; do
      databricks volumes get $CATALOG.$schema.raw_files
    done
    
    echo "All verification checks passed"
```

---

## 6. Databricks Asset Bundle (DAB) Configuration

After Terraform provisions infrastructure, DAB deploys the code.

```yaml
# bundle/databricks.yml

bundle:
  name: gharchive_pipelines

variables:
  catalog:
    description: "Target catalog name (from Terraform output)"
  runtime_sp_name:
    description: "Service principal to run jobs/pipelines"

include:
  - resources/*.yml

targets:
  test:
    mode: development
    default: true
    workspace:
      host: ${DATABRICKS_HOST}
    variables:
      catalog: gharchive_test
    run_as:
      service_principal_name: ${var.runtime_sp_name}

  dev:
    mode: development
    workspace:
      host: ${DATABRICKS_HOST}
    variables:
      catalog: gharchive_dev
    run_as:
      service_principal_name: ${var.runtime_sp_name}

  prod:
    mode: production
    workspace:
      host: ${DATABRICKS_HOST}
    variables:
      catalog: gharchive_prod
    run_as:
      service_principal_name: ${var.runtime_sp_name}
    permissions:
      - service_principal_name: ${var.runtime_sp_name}
        level: CAN_MANAGE
```

### Resource Definitions

```yaml
# bundle/resources/v2_pipeline.yml

resources:
  pipelines:
    v2_pipeline:
      name: "GH Archive V2 - ${bundle.target}"
      catalog: ${var.catalog}
      schema: v2_pipeline
      serverless: true
      photon: true
      channel: CURRENT
      libraries:
        - notebook:
            path: ../src/v2_pipeline/pipeline

  jobs:
    v2_pipeline_hourly:
      name: "v2_pipeline_hourly_${bundle.target}"
      schedule:
        quartz_cron_expression: "0 0 * * * ?"
        timezone_id: "Asia/Calcutta"
      tasks:
        - task_key: ingest
          spark_python_task:
            python_file: ../src/v2_pipeline/ingest.py
        - task_key: run_pipeline
          depends_on:
            - task_key: ingest
          pipeline_task:
            pipeline_id: ${resources.pipelines.v2_pipeline.id}
```

```yaml
# bundle/resources/v3_autoloader.yml

resources:
  pipelines:
    v3_autoloader:
      name: "GH Archive V3 - ${bundle.target}"
      catalog: ${var.catalog}
      schema: v3_autoloader
      serverless: true
      photon: true
      channel: CURRENT
      libraries:
        - notebook:
            path: ../src/v3_autoloader/pipeline

  jobs:
    v3_autoloader_hourly:
      name: "v3_autoloader_hourly_${bundle.target}"
      schedule:
        quartz_cron_expression: "37 5 * * * ?"
        timezone_id: "Asia/Calcutta"
      tasks:
        - task_key: ingest
          spark_python_task:
            python_file: ../src/v3_autoloader/ingest.py
        - task_key: pipeline_update
          depends_on:
            - task_key: ingest
          pipeline_task:
            pipeline_id: ${resources.pipelines.v3_autoloader.id}
```

---

## 7. GitHub Actions Workflow

```yaml
# .github/workflows/deploy.yml

name: Deploy GH Archive Pipelines

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      environment:
        description: 'Target environment'
        required: true
        type: choice
        options: [test, dev, staging, prod]
      skip_terraform:
        description: 'Skip infrastructure provisioning'
        required: false
        type: boolean
        default: false

env:
  DATABRICKS_HOST: ${{ secrets.DATABRICKS_HOST }}
  DATABRICKS_TOKEN: ${{ secrets.SP_TOKEN }}

jobs:
  # Phase 1: Infrastructure
  terraform:
    name: "Provision Infrastructure"
    runs-on: ubuntu-latest
    if: ${{ !inputs.skip_terraform }}
    outputs:
      catalog_name: ${{ steps.tf-output.outputs.catalog_name }}
    
    steps:
      - uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.7.0

      - name: Terraform Init
        working-directory: terraform
        run: terraform init

      - name: Terraform Plan
        working-directory: terraform
        run: |
          terraform plan \
            -var="environment_prefix=${{ inputs.environment || 'dev' }}" \
            -var="databricks_host=${{ secrets.DATABRICKS_HOST }}" \
            -var="runtime_sp_name=${{ secrets.RUNTIME_SP_NAME }}" \
            -out=tfplan

      - name: Terraform Apply
        working-directory: terraform
        run: terraform apply -auto-approve tfplan

      - name: Get Terraform Outputs
        id: tf-output
        working-directory: terraform
        run: |
          echo "catalog_name=$(terraform output -raw catalog_name)" >> $GITHUB_OUTPUT

  # Phase 1.5: Verify Environment
  verify:
    name: "Verify Environment"
    runs-on: ubuntu-latest
    needs: [terraform]
    if: always() && (needs.terraform.result == 'success' || inputs.skip_terraform)

    steps:
      - uses: actions/checkout@v4
      
      - name: Install Databricks CLI
        run: curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh

      - name: Verify catalog and schemas
        run: |
          CATALOG="gharchive_${{ inputs.environment || 'dev' }}"
          databricks catalogs get $CATALOG
          for schema in v1_pyspark v2_pipeline v3_autoloader; do
            databricks schemas get $CATALOG.$schema
          done
          echo "All checks passed"

  # Phase 2: Deploy Code
  deploy:
    name: "Deploy Bundles"
    runs-on: ubuntu-latest
    needs: [verify]

    steps:
      - uses: actions/checkout@v4

      - name: Install Databricks CLI
        run: curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh

      - name: Validate Bundle
        working-directory: bundle
        run: databricks bundle validate -t ${{ inputs.environment || 'dev' }}

      - name: Deploy Bundle
        working-directory: bundle
        run: databricks bundle deploy -t ${{ inputs.environment || 'dev' }}

      - name: Run Verification Job (test only)
        if: inputs.environment == 'test'
        working-directory: bundle
        run: databricks bundle run v3_autoloader_hourly -t test
```

---

## 8. GitHub Secrets Required

| Secret | Description | Example |
|---|---|---|
| DATABRICKS_HOST | Workspace URL | https://dbc-xxx.cloud.databricks.com |
| SP_TOKEN | Deployer SP OAuth token | dapi... |
| SP_CLIENT_ID | Deployer SP client ID | xxxxxxxx-xxxx-... |
| SP_CLIENT_SECRET | Deployer SP client secret | dose... |
| RUNTIME_SP_NAME | Runtime SP display name | gharchive-runner |

---

## 9. Deployment Flow Summary

```
Developer pushes to main
         │
         v
GitHub Actions triggers
         │
         v
┌─── Phase 1: Terraform ───────────────────────┐
│  1. Create/reuse deployer SP                  │
│  2. Create catalog: gharchive_{prefix}        │
│  3. Create schemas: v1_pyspark, v2_pipeline,  │
│     v3_autoloader                             │
│  4. Create volumes per schema                 │
│  5. Grant runtime SP permissions              │
│     (incl. CREATE_MATERIALIZED_VIEW)          │
│  6. Run verification checks                   │
└───────────────────────────────────────────────┘
         │
         v
┌─── Phase 1.5: Verify ────────────────────────┐
│  1. Verify catalog accessible                 │
│  2. Verify all schemas exist                  │
│  3. Verify volumes exist                      │
│  4. Verify SP permissions work                │
└───────────────────────────────────────────────┘
         │
         v
┌─── Phase 2: DAB Deploy ──────────────────────┐
│  1. databricks bundle validate                │
│  2. databricks bundle deploy                  │
│     -> Deploys notebooks/code to workspace    │
│     -> Creates/updates pipelines (run_as SP)  │
│     -> Creates/updates jobs with schedules    │
│     -> Sets CAN_MANAGE on pipelines for SP    │
│  3. (test only) Trigger verification run      │
└───────────────────────────────────────────────┘
```

---

## 10. Open Decisions

| Decision | Options | Recommendation |
|---|---|---|
| Terraform state backend | Local, S3, Terraform Cloud | S3 bucket with DynamoDB locking |
| Workspace creation | Terraform or manual | Manual (one-time, complex AWS setup) |
| Volume per pipeline or shared | Separate vs shared | Separate (isolation) |
| SP authentication | OAuth M2M or PAT | OAuth M2M (more secure) |
| Branch strategy | trunk-based or GitFlow | Trunk-based: main -> prod |
| DAB mode for test | development or production | development (iterative) |
| Ingest task type | Python script vs notebook | Notebook (dbutils.widgets) |

---

## 11. Commands Reference

```bash
# Initialize Terraform
cd terraform && terraform init

# Plan for test environment
terraform plan -var="environment_prefix=test" -var="databricks_host=https://..." -var="runtime_sp_name=gharchive-runner"

# Apply
terraform apply -var="environment_prefix=test" ...

# Deploy bundle to test
cd ../bundle && databricks bundle validate -t test
databricks bundle deploy -t test

# Run a specific job
databricks bundle run v3_autoloader_hourly -t test

# Destroy test environment
cd ../terraform && terraform destroy -var="environment_prefix=test" ...
```