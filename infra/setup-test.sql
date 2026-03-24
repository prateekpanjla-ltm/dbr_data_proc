-- ============================================================
-- Test environment: Unity Catalog setup
-- Creates catalog, schema, and volume for GH Archive pipeline
-- ============================================================

CREATE CATALOG IF NOT EXISTS gharchive_test;
CREATE SCHEMA IF NOT EXISTS gharchive_test.pipeline;
CREATE VOLUME IF NOT EXISTS gharchive_test.pipeline.raw_files;

-- Grant workspace users access
GRANT USE CATALOG ON CATALOG gharchive_test TO `account users`;
GRANT USE SCHEMA ON SCHEMA gharchive_test.pipeline TO `account users`;
GRANT READ VOLUME, WRITE VOLUME ON VOLUME gharchive_test.pipeline.raw_files TO `account users`;
GRANT CREATE TABLE ON SCHEMA gharchive_test.pipeline TO `account users`;

-- Verify
SHOW VOLUMES IN gharchive_test.pipeline;