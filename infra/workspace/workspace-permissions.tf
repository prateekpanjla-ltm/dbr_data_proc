# ============================================================
# Workspace-level permissions for the service principal
# These CANNOT be granted via SQL — requires SCIM API calls.
# Uses Terraform local-exec to call the Databricks REST API.
# ============================================================
#
# Why local-exec?
# - Unity Catalog grants (USE CATALOG, CREATE TABLE, etc.) are done via SQL
# - Workspace entitlements (workspace-access, sql-access) require the SCIM API
# - local-exec bridges this gap by running API calls from the Terraform runner
#
# To run standalone:
#   cd infra/workspace && terraform init && terraform apply -var-file=../dev.tfvars
#
# Requires environment variables:
#   DATABRICKS_CLIENT_ID, DATABRICKS_CLIENT_SECRET
# ============================================================

terraform {
  required_version = ">= 1.5.0"
}

variable "databricks_host" {
  description = "Databricks workspace URL"
  type        = string
}

variable "service_principal_id" {
  description = "Service principal application ID"
  type        = string
  default     = "13713ce5-dcb8-4a71-be94-28b533c10461"
}

# ============================================================
# Step 1: Look up the SP's internal SCIM ID
# (SCIM API requires the internal numeric ID, not the app ID)
# ============================================================
resource "null_resource" "sp_workspace_permissions" {

  triggers = {
    sp_id = var.service_principal_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -e

      HOST="${var.databricks_host}"
      CLIENT_ID="$DATABRICKS_CLIENT_ID"
      CLIENT_SECRET="$DATABRICKS_CLIENT_SECRET"

      # Get OAuth access token
      echo "Getting OAuth token..."
      TOKEN=$(curl -s -X POST "$HOST/oidc/v1/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials" \
        -d "client_id=$CLIENT_ID" \
        -d "client_secret=$CLIENT_SECRET" \
        -d "scope=all-apis" | jq -r '.access_token')

      if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
        echo "ERROR: Failed to get OAuth token"
        exit 1
      fi
      echo "OAuth token obtained."

      # Look up SP's SCIM ID using the application ID
      echo "Looking up service principal SCIM ID..."
      SP_SCIM_ID=$(curl -s -X GET \
        "$HOST/api/2.0/preview/scim/v2/ServicePrincipals?filter=applicationId+eq+${var.service_principal_id}" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/scim+json" | jq -r '.Resources[0].id')

      if [ -z "$SP_SCIM_ID" ] || [ "$SP_SCIM_ID" = "null" ]; then
        echo "ERROR: Service principal not found"
        exit 1
      fi
      echo "Found SCIM ID: $SP_SCIM_ID"

      # Grant workspace-access and databricks-sql-access entitlements
      echo "Granting workspace entitlements..."
      HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" -X PATCH \
        "$HOST/api/2.0/preview/scim/v2/ServicePrincipals/$SP_SCIM_ID" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/scim+json" \
        -d '{
          "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
          "Operations": [
            {
              "op": "add",
              "path": "entitlements",
              "value": [
                {"value": "workspace-access"},
                {"value": "databricks-sql-access"}
              ]
            }
          ]
        }')

      if [ "$HTTP_CODE" = "200" ]; then
        echo "SUCCESS: Workspace entitlements granted."
      else
        echo "ERROR: Failed to grant entitlements. HTTP code: $HTTP_CODE"
        exit 1
      fi
    EOT
  }
}

output "note" {
  value = "Workspace entitlements (workspace-access, databricks-sql-access) granted to SP ${var.service_principal_id}"
}