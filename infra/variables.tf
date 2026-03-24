# ============================================================
# Variables for Unity Catalog infrastructure
# ============================================================

variable "databricks_host" {
  description = "Databricks workspace URL (e.g., https://adb-xxxx.azuredatabricks.net)"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, test, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be one of: dev, test, prod."
  }
}

variable "catalog_name" {
  description = "Name of the Unity Catalog catalog to create"
  type        = string
}

variable "schema_name" {
  description = "Name of the schema within the catalog"
  type        = string
  default     = "pipeline"
}

variable "volume_name" {
  description = "Name of the managed volume for raw files"
  type        = string
  default     = "raw_files"
}