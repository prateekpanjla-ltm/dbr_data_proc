-- ============================================================
-- BOOTSTRAP: Run this ONCE manually before using GitHub Actions
-- Creates a volume to store Terraform state files
-- ============================================================

-- 1. Create the terraform catalog (manually provisioned)
CREATE CATALOG IF NOT EXISTS gharchive_terraform;

-- 2. Create schema and volume for Terraform state
CREATE SCHEMA IF NOT EXISTS gharchive_terraform.tf_state;
CREATE VOLUME IF NOT EXISTS gharchive_terraform.tf_state.files;

-- 3. Grant the service principal access to read/write state
-- Replace <service-principal-application-id> with your SP's application ID
GRANT USE CATALOG ON CATALOG gharchive_terraform TO `<service-principal-application-id>`;
GRANT USE SCHEMA ON SCHEMA gharchive_terraform.tf_state TO `<service-principal-application-id>`;
GRANT READ VOLUME, WRITE VOLUME ON VOLUME gharchive_terraform.tf_state.files TO `<service-principal-application-id>`;

-- 4. Verify
SHOW VOLUMES IN gharchive_terraform.tf_state;