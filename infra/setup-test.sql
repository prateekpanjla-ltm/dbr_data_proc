-- ============================================================
-- Test environment: Unity Catalog setup
-- Creates catalog, schema, and volume for GH Archive pipeline
-- ============================================================

CREATE CATALOG IF NOT EXISTS gharchive_test;
CREATE SCHEMA IF NOT EXISTS gharchive_test.pipeline;
CREATE VOLUME IF NOT EXISTS gharchive_test.pipeline.raw_files;

-- Verify
SHOW VOLUMES IN gharchive_test.pipeline;