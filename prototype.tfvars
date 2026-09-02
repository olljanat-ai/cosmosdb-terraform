# Prototype environment.
#
#   terraform init
#   terraform apply -var-file=prototype.tfvars
#
# `cosmosdb_account_name` is part of a public DNS name and has to be globally
# unique, so change it before the first apply.

resource_group_name   = "rg-cosmosdb-prototype"
location              = "swedencentral"
cosmosdb_account_name = "cosmosdb-mongo-prototype"

# The one database of the account, with dedicated provisioned throughput. Use
# `database_max_throughput` instead for autoscale.
database_name       = "orders"
database_throughput = 400

# The user that owns it. The username defaults to the database name, and the
# password is generated unless one is given here.
#
# database_username = "orders-app"
# database_password = "..."

# The managed identity that reaches the same database with its own Entra ID
# token instead of a password. Attach it to whatever runs the workload.
# `DocumentDB Account Contributor` is read-write, `Cosmos DB Account Reader
# Role` is read-only.
managed_identity_name                 = "id-cosmosdb-prototype-app"
managed_identity_role_definition_name = "DocumentDB Account Contributor"

# Key Vault for the generated password and the connection string built from it.
# The name is part of a public DNS name and has to be globally unique too, so
# change it along with the account name.
key_vault_name = "kv-cosmosdb-prototype"

# Off, so that `terraform destroy` really releases the name of a prototype vault.
# Turn it on for anything that is not a prototype.
key_vault_purge_protection_enabled = false

# Whoever runs the apply gets `Key Vault Secrets Officer` on the vault, which is
# what lets Terraform write the secrets in the first place.
key_vault_grant_deployer_access = true

# The managed identity gets `Key Vault Secrets User`, so the workload reads the
# password from the vault rather than carrying it in its configuration.
key_vault_grant_managed_identity_access = true

# Anyone else who reads the secrets back, for example a group of operators.
#
# key_vault_reader_principal_ids = ["00000000-0000-0000-0000-000000000000"]

tags = {
  environment = "prototype"
  managed_by  = "terraform"
}
