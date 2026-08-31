output "resource_group_name" {
  description = "Name of the resource group holding the environment."
  value       = module.resource_group.name
}

output "cosmosdb_account_id" {
  description = "Resource ID of the Cosmos DB account."
  value       = module.cosmosdb_account.resource_id
}

output "cosmosdb_account_name" {
  description = "Name of the Cosmos DB account, needed to look the connection string up at runtime."
  value       = module.cosmosdb_account.name
}

output "endpoint" {
  description = "Endpoint of the Cosmos DB account."
  value       = module.cosmosdb_account.endpoint
}

output "mongodb_host" {
  description = "MongoDB host name of the account. Port 10255, TLS required."
  value       = local.mongodb_host
}

output "database_ids" {
  description = "Resource ID of every created database, keyed by database name."
  value       = { for name, db in module.cosmosdb_account.mongo_databases : name => db.id }
}

output "database_users" {
  description = "Owner credentials and connection string of every database that has a user of its own, keyed by database name."
  sensitive   = true
  value = {
    for name, user in azurerm_cosmosdb_mongo_user_definition.this : name => {
      username          = user.username
      password          = local.passwords[name]
      connection_string = local.connection_strings[name]
    }
  }
}

output "entra_id_identities" {
  description = "Client ID, principal ID and granted role of every managed identity created for this environment, keyed by identity name."
  value = {
    for name, identity in module.user_assigned_identity : name => {
      client_id            = identity.client_id
      principal_id         = identity.principal_id
      role_definition_name = local.identities[name].role_definition_name
    }
  }
}

output "entra_id_role_assignment_ids" {
  description = "Resource ID of every Entra ID role assignment on the account. The Cosmos DB module keys them by the name Azure gave the assignment, a GUID, not by the key they were passed in under."
  value       = module.cosmosdb_account.resource_role_assignments
}

output "primary_mongodb_connection_string" {
  description = "Account level MongoDB connection string. It carries the account key and grants access to every database, prefer the per-database users."
  sensitive   = true
  value       = module.cosmosdb_account.cosmosdb_mongodb_connection_strings.primary_mongodb_connection_string
}

output "key_vault_id" {
  description = "Resource ID of the Key Vault holding the database secrets, null when `key_vault_enabled` is false."
  value       = one(module.key_vault[*].resource_id)
}

output "key_vault_name" {
  description = "Name of the Key Vault, null when `key_vault_enabled` is false."
  value       = one(module.key_vault[*].name)
}

output "key_vault_uri" {
  description = "URI of the Key Vault, for example `https://<vault>.vault.azure.net/`. Null when `key_vault_enabled` is false."
  value       = one(module.key_vault[*].uri)
}

output "key_vault_secret_names" {
  description = "Name of the password and connection string secret of every database that has a user of its own, keyed by database name."
  value = var.key_vault_enabled ? {
    for name in keys(local.users) : name => {
      password          = module.key_vault[0].secrets_resource_ids["${name}-password"].name
      connection_string = module.key_vault[0].secrets_resource_ids["${name}-connection-string"].name
    }
  } : {}
}
