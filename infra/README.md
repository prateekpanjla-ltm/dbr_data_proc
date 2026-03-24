# Unity Catalog Infrastructure Setup

Terraform configuration to provision Unity Catalog resources (catalog, schema, volume) for the GH Archive pipeline.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- [Databricks CLI](https://docs.databricks.com/dev-tools/cli/install.html) (for authentication)
- Databricks Personal Access Token with catalog creation privileges

## Authentication

Set the following environment variables:

```bash
export DATABRICKS_TOKEN="dapi..."
```

## Usage

### Initialize Terraform

```bash
cd infra/
terraform init
```

### Deploy to Dev

```bash
terraform plan  -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

### Deploy to Test

```bash
terraform plan  -var-file=test.tfvars
terraform apply -var-file=test.tfvars
```

### Destroy (tear down an environment)

```bash
terraform destroy -var-file=dev.tfvars
```

## Files

| File | Purpose |
|------|--------|
| `main.tf` | Provider config + Unity Catalog resources (catalog, schema, volume) |
| `variables.tf` | Input variable definitions |
| `outputs.tf` | Output values (catalog name, schema name, volume path) |
| `dev.tfvars` | Dev environment variable values |
| `test.tfvars` | Test environment variable values |

## Created Resources

For each environment, this creates:

1. **Catalog** - `gharchive_<env>` - top-level container
2. **Schema** - `gharchive_<env>.pipeline` - houses bronze/silver/gold tables
3. **Volume** - `gharchive_<env>.pipeline.raw_files` - managed storage for raw JSON files

## Volume Path

After provisioning, upload GH Archive files to:

```
/Volumes/gharchive_<env>/pipeline/raw_files/
```
