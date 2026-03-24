-- ============================================================
-- Dev environment: Unity Catalog setup
-- Creates catalog, schema, and volume for GH Archive pipeline
-- ============================================================

CREATE CATALOG IF NOT EXISTS gharchive_dev;
CREATE SCHEMA IF NOT EXISTS gharchive_dev.pipeline;
CREATE VOLUME IF NOT EXISTS gharchive_dev.pipeline.raw_files;

-- Verify
SHOW VOLUMES IN gharchive_dev.pipeline;