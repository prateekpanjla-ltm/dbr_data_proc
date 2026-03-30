# ============================================================
# Terraform configuration for Unity Catalog infrastructure
# Provisions: Catalog, Schemas, Volume, and Grants per environment
# ============================================================

terraform {
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = ">= 1.50.0"
    }
  }
  required_version = ">= 1.5.0"
}

# ============================================================
# Provider - authenticates via environment variables:
#   DATABRICKS_HOST and DATABRICKS_TOKEN
# ============================================================
provider "databricks" {
  host = var.databricks_host
}

# ============================================================
# 1. Catalog - top-level container for the environment
# ============================================================
resource "databricks_catalog" "gharchive" {
  name    = var.catalog_name
  comment = "GH Archive data pipeline - ${var.environment} environment"

  properties = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

# ============================================================
# 2. Schemas - one per pipeline version + raw storage
# ============================================================
resource "databricks_schema" "raw" {
  catalog_name = databricks_catalog.gharchive.name
  name         = "raw"
  comment      = "Raw GH Archive JSON files (Volume storage)"

  properties = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "databricks_schema" "v1_pyspark" {
  catalog_name = databricks_catalog.gharchive.name
  name         = "v1_pyspark"
  comment      = "V1 PySpark pipeline tables (bronze, silver, gold)"

  properties = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "databricks_schema" "v2_pipeline" {
  catalog_name = databricks_catalog.gharchive.name
  name         = "v2_pipeline"
  comment      = "V2 Declarative Pipeline tables (DLT/Lakeflow)"

  properties = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "databricks_schema" "v3_autoloader" {
  catalog_name = databricks_catalog.gharchive.name
  name         = "v3_autoloader"
  comment      = "V3 Auto Loader pipeline tables (streaming DLT)"

  properties = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

# ============================================================
# 3. Volume - managed storage for raw GH Archive JSON files
# ============================================================
resource "databricks_volume" "raw_files" {
  catalog_name = databricks_catalog.gharchive.name
  schema_name  = databricks_schema.raw.name
  name         = var.volume_name
  volume_type  = "MANAGED"
  comment      = "Raw GH Archive JSON files for ingestion"
}

# ============================================================
# 4. Unity Catalog Grants
# ============================================================

# Catalog-level grants
resource "databricks_grants" "catalog" {
  catalog = databricks_catalog.gharchive.name

  grant {
    principal  = var.pipeline_runner_principal
    privileges = ["USE_CATALOG"]
  }
}

# V1 PySpark schema - standard tables only
resource "databricks_grants" "v1_pyspark" {
  schema = "${databricks_catalog.gharchive.name}.${databricks_schema.v1_pyspark.name}"

  grant {
    principal  = var.pipeline_runner_principal
    privileges = ["USE_SCHEMA", "CREATE_TABLE", "SELECT", "MODIFY"]
  }
}

# ------------------------------------------------------------
# IMPORTANT: DLT/Lakeflow Declarative Pipelines create
# MATERIALIZED VIEWS, not regular tables. Without
# CREATE_MATERIALIZED_VIEW the pipeline fails with:
#   PERMISSION_DENIED: User does not have CREATE MATERIALIZED
#   VIEW on Schema '...'
#
# This grant is NOT needed for V1 (plain PySpark saveAsTable)
# but IS required for V2 (Declarative Pipelines) and V3
# (Auto Loader with Declarative Pipelines).
# ------------------------------------------------------------

# V2 Declarative Pipeline schema - needs CREATE_MATERIALIZED_VIEW
resource "databricks_grants" "v2_pipeline" {
  schema = "${databricks_catalog.gharchive.name}.${databricks_schema.v2_pipeline.name}"

  grant {
    principal  = var.pipeline_runner_principal
    privileges = [
      "USE_SCHEMA",
      "CREATE_TABLE",
      "CREATE_MATERIALIZED_VIEW",  # Required for DLT @dp.table definitions
      "SELECT",
      "MODIFY"
    ]
  }
}

# V3 Auto Loader schema - also needs CREATE_MATERIALIZED_VIEW
resource "databricks_grants" "v3_autoloader" {
  schema = "${databricks_catalog.gharchive.name}.${databricks_schema.v3_autoloader.name}"

  grant {
    principal  = var.pipeline_runner_principal
    privileges = [
      "USE_SCHEMA",
      "CREATE_TABLE",
      "CREATE_MATERIALIZED_VIEW",  # Required for DLT @dp.table definitions
      "SELECT",
      "MODIFY"
    ]
  }
}

# Raw schema - for Volume access
resource "databricks_grants" "raw" {
  schema = "${databricks_catalog.gharchive.name}.${databricks_schema.raw.name}"

  grant {
    principal  = var.pipeline_runner_principal
    privileges = ["USE_SCHEMA", "READ_VOLUME", "WRITE_VOLUME"]
  }
}