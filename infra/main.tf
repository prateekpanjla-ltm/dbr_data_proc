# ============================================================
# Terraform configuration for Unity Catalog infrastructure
# Provisions: Catalog, Schema, and Volume per environment
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
# 2. Schema - houses pipeline tables (bronze, silver, gold)
# ============================================================
resource "databricks_schema" "pipeline" {
  catalog_name = databricks_catalog.gharchive.name
  name         = var.schema_name
  comment      = "Schema for GH Archive pipeline tables"

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
  schema_name  = databricks_schema.pipeline.name
  name         = var.volume_name
  volume_type  = "MANAGED"
  comment      = "Raw GH Archive JSON files for ingestion"
}