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

-- ============================================================
-- Grant workspace users access (Unity Catalog level)
-- ============================================================
GRANT USE CATALOG ON CATALOG gharchive_dev TO `account users`;
GRANT USE SCHEMA, CREATE TABLE ON SCHEMA gharchive_dev.raw TO `account users`;
GRANT READ VOLUME, WRITE VOLUME ON VOLUME gharchive_dev.raw.files TO `account users`;
GRANT USE SCHEMA, CREATE TABLE ON SCHEMA gharchive_dev.v1_pyspark TO `account users`;
GRANT USE SCHEMA, CREATE TABLE ON SCHEMA gharchive_dev.v2_pipeline TO `account users`;
GRANT USE SCHEMA, CREATE TABLE ON SCHEMA gharchive_dev.v3_autoloader TO `account users`;

-- ============================================================
-- Grant service principal access (Unity Catalog level)
-- SP Application ID: 13713ce5-dcb8-4a71-be94-28b533c10461
-- ============================================================
GRANT USE CATALOG ON CATALOG gharchive_dev TO `13713ce5-dcb8-4a71-be94-28b533c10461`;
GRANT USE SCHEMA, CREATE TABLE ON SCHEMA gharchive_dev.raw TO `13713ce5-dcb8-4a71-be94-28b533c10461`;
GRANT READ VOLUME ON VOLUME gharchive_dev.raw.files TO `13713ce5-dcb8-4a71-be94-28b533c10461`;
GRANT USE SCHEMA, CREATE TABLE ON SCHEMA gharchive_dev.v1_pyspark TO `13713ce5-dcb8-4a71-be94-28b533c10461`;
GRANT USE SCHEMA, CREATE TABLE ON SCHEMA gharchive_dev.v2_pipeline TO `13713ce5-dcb8-4a71-be94-28b533c10461`;
GRANT USE SCHEMA, CREATE TABLE ON SCHEMA gharchive_dev.v3_autoloader TO `13713ce5-dcb8-4a71-be94-28b533c10461`;

-- ============================================================
-- NOTE: Workspace-level permissions CANNOT be granted via SQL.
-- The following entitlements are required for the service principal
-- to create and manage pipelines/jobs via DABs:
--   - workspace-access
--   - databricks-sql-access
-- These are granted via the Databricks SCIM API using Terraform
-- local-exec in: infra/workspace/workspace-permissions.tf
-- (Runs as part of the infra-deploy.yml GitHub Actions workflow)
-- ============================================================

-- Verify
SHOW SCHEMAS IN gharchive_dev;