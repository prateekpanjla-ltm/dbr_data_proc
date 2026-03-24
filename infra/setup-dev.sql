-- ============================================================
-- Dev environment: Unity Catalog setup
-- Creates catalog, schema, and volume for GH Archive pipeline
-- ============================================================

CREATE CATALOG IF NOT EXISTS gharchive_dev;
CREATE SCHEMA IF NOT EXISTS gharchive_dev.pipeline;
CREATE VOLUME IF NOT EXISTS gharchive_dev.pipeline.raw_files;

-- Grant workspace users access
GRANT USE CATALOG ON CATALOG gharchive_dev TO `account users`;
GRANT USE SCHEMA ON SCHEMA gharchive_dev.pipeline TO `account users`;
GRANT READ VOLUME, WRITE VOLUME ON VOLUME gharchive_dev.pipeline.raw_files TO `account users`;
GRANT CREATE TABLE ON SCHEMA gharchive_dev.pipeline TO `account users`;

-- Verify
SHOW VOLUMES IN gharchive_dev.pipeline;