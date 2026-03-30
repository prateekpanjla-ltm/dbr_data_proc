-- ============================================================
-- BOOTSTRAP: Run this ONCE manually before using GitHub Actions
--
-- Purpose: Grant the DEPLOYER service principal enough permissions
-- to run Terraform and DAB. Terraform then grants the RUNTIME SP
-- its permissions automatically (no manual step).
--
-- Grant Chain:
--   Admin (you, manually)  →  Deployer SP (Terraform/DAB in CI/CD)
--   Deployer SP (Terraform) →  Runtime SP (runs jobs/pipelines)
--
-- Prerequisites:
--   1. Deployer SP must already exist in the account
--   2. You must be a metastore admin or account admin
-- ============================================================

-- ============================================================
-- STEP 1: Deployer SP — Metastore-Level Grants
-- This lets the deployer create catalogs for any environment
-- (gharchive_test, gharchive_dev, gharchive_prod, etc.)
-- ============================================================

-- Replace <deployer-sp-application-id> with your deployer SP's application ID
-- Find it: Account Console → Service Principals → Application ID

GRANT CREATE CATALOG ON METASTORE TO `<deployer-sp-application-id>`;

-- NOTE: Once the deployer creates a catalog, it becomes the OWNER.
-- As owner, it automatically gets full permissions on:
--   - The catalog itself
--   - Any schemas it creates inside
--   - Any tables, volumes, functions it creates inside
--   - The ability to GRANT permissions to others (runtime SP)
-- So no additional grants are needed for schema/table/volume creation.

-- ============================================================
-- STEP 2: Terraform State Backend
-- Create a dedicated catalog + volume to store .tfstate files
-- This is separate from the pipeline data catalogs
-- ============================================================

CREATE CATALOG IF NOT EXISTS gharchive_terraform;
CREATE SCHEMA IF NOT EXISTS gharchive_terraform.tf_state;
CREATE VOLUME IF NOT EXISTS gharchive_terraform.tf_state.files;

-- Grant the deployer SP access to read/write Terraform state
GRANT USE CATALOG ON CATALOG gharchive_terraform TO `<deployer-sp-application-id>`;
GRANT USE SCHEMA ON SCHEMA gharchive_terraform.tf_state TO `<deployer-sp-application-id>`;
GRANT READ VOLUME, WRITE VOLUME ON VOLUME gharchive_terraform.tf_state.files TO `<deployer-sp-application-id>`;

-- ============================================================
-- STEP 3: Create V3 Isolated Volume (dev environment)
-- V3 Auto Loader needs its own volume, separate from V1's
-- shared volume at /Volumes/gharchive_dev/raw/files
-- ============================================================

CREATE VOLUME IF NOT EXISTS gharchive_dev.v3_autoloader.raw_files;

-- ============================================================
-- STEP 4: Verify Bootstrap
-- ============================================================

SHOW VOLUMES IN gharchive_terraform.tf_state;
SHOW VOLUMES IN gharchive_dev.v3_autoloader;

-- Check deployer SP grants
-- SHOW GRANTS TO `<deployer-sp-application-id>`;

-- ============================================================
-- WHAT TERRAFORM WILL DO NEXT (automated, not manual):
--
-- 1. Create catalog:  gharchive_{prefix}  (e.g., gharchive_test)
-- 2. Create schemas:  v1_pyspark, v2_pipeline, v3_autoloader
-- 3. Create volumes:  raw_files in each schema
-- 4. Grant runtime SP on catalog:
--      USE_CATALOG, USE_SCHEMA, SELECT, MODIFY,
--      CREATE_TABLE, CREATE_MATERIALIZED_VIEW,
--      CREATE_FUNCTION, READ_VOLUME, WRITE_VOLUME
-- 5. Grant runtime SP on each schema:
--      USE_SCHEMA, SELECT, MODIFY, CREATE_TABLE,
--      CREATE_MATERIALIZED_VIEW, CREATE_FUNCTION,
--      READ_VOLUME, WRITE_VOLUME
--
-- WHAT DAB WILL DO AFTER TERRAFORM (automated):
-- 6. Deploy notebooks/code to workspace
-- 7. Create pipelines with run_as = runtime SP
-- 8. Create jobs with schedules
-- 9. Set CAN_MANAGE on pipelines for runtime SP
-- ============================================================