# Prototype environment.
#
#   terraform init
#   terraform apply -var-file=prototype.tfvars
#
# `cosmosdb_account_name` is part of a public DNS name and has to be globally
# unique, so change it before the first apply.

resource_group_name   = "rg-cosmosdb-prototype"
location              = "West Europe"
cosmosdb_account_name = "cosmosdb-mongo-prototype"

# One account, and the test databases below all live in it. Each one covers a
# different type of database so the prototype exercises them side by side.
databases = [
  {
    # Dedicated provisioned throughput, owner of its own with a generated password.
    name       = "orders"
    throughput = 400
  },
  {
    # Autoscaling throughput, and a username that differs from the database name.
    name           = "invoices"
    max_throughput = 1000
    username       = "invoices-app"
  },
  {
    # No dedicated throughput and no user at all. Reached only through the Entra ID
    # identities below, so nothing anywhere holds a password for it.
    name        = "telemetry"
    create_user = false
  },
]

# Managed identities that authenticate with their own Entra ID token instead of a
# username and password. Attach them to whatever runs the workload.
entra_id_identities = [
  {
    # Read and write, because writing needs the read-write account keys.
    name                 = "id-cosmosdb-prototype-app"
    role_definition_name = "DocumentDB Account Contributor"
  },
  {
    # Read only, this role hands out the read-only keys.
    name                 = "id-cosmosdb-prototype-reporting"
    role_definition_name = "Cosmos DB Account Reader Role"
  },
]

# Entra ID principals that already exist elsewhere, for example a group of
# operators or another team's service principal.
#
# entra_id_access = [
#   {
#     principal_id         = "00000000-0000-0000-0000-000000000000"
#     role_definition_name = "Cosmos DB Account Reader Role"
#     principal_type       = "Group"
#   },
# ]

tags = {
  environment = "prototype"
  managed_by  = "terraform"
}
