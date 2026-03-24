-- ============================================================
-- Dev environment: Unity Catalog setup
-- Creates catalog, schemas, and volume for GH Archive pipeline
-- ============================================================

CREATE CATALOG IF NOT EXISTS gharchive_dev;

-- Shared volume for raw JSON files (all versions read from here)
CREATE SCHEMA IF NOT EXISTS gharchive_dev.raw;
CREATE VOLUME IF NOT EXISTS gharchive_dev.raw.files;

-- V1: Plain PySpark tables
CREATE SCHEMA IF NOT EXISTS gharchive_dev.v1_pyspark;

-- V2: Lakeflow Pipeline tables (separate notebooks)
CREATE SCHEMA IF NOT EXISTS gharchive_dev.v2_pipeline;

-- V3: Auto Loader Pipeline tables (single notebook, streaming)
CREATE SCHEMA IF NOT EXISTS gharchive_dev.v3_autoloader;

-- Grant workspace users access
GRANT USE CATALOG ON CATALOG gharchive_dev TO `account users`;
GRANT USE SCHEMA, CREATE TABLE ON SCHEMA gharchive_dev.raw TO `account users`;
GRANT READ VOLUME, WRITE VOLUME ON VOLUME gharchive_dev.raw.files TO `account users`;
GRANT USE SCHEMA, CREATE TABLE ON SCHEMA gharchive_dev.v1_pyspark TO `account users`;
GRANT USE SCHEMA, CREATE TABLE ON SCHEMA gharchive_dev.v2_pipeline TO `account users`;
GRANT USE SCHEMA, CREATE TABLE ON SCHEMA gharchive_dev.v3_autoloader TO `account users`;

-- Verify
SHOW SCHEMAS IN gharchive_dev;