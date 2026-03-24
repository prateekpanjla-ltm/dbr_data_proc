# ============================================================
# Outputs - expose created resource details
# ============================================================

output "catalog_name" {
  description = "Name of the created catalog"
  value       = databricks_catalog.gharchive.name
}

output "schema_full_name" {
  description = "Fully qualified schema name (catalog.schema)"
  value       = "${databricks_catalog.gharchive.name}.${databricks_schema.pipeline.name}"
}

output "volume_path" {
  description = "Volume path for raw file ingestion"
  value       = "/Volumes/${databricks_catalog.gharchive.name}/${databricks_schema.pipeline.name}/${databricks_volume.raw_files.name}"
}