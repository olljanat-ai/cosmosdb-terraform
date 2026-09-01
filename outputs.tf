output "resource_group_name" {
  description = "Name of the resource group holding the environment."
  value       = azurerm_resource_group.this.name
}

output "cosmosdb_account_id" {
  description = "Resource ID of the Cosmos DB account."
  value       = azurerm_cosmosdb_account.this.id
}

output "cosmosdb_account_name" {
  description = "Name of the Cosmos DB account, needed to look the connection string up at runtime."
  value       = azurerm_cosmosdb_account.this.name
}

output "endpoint" {
  description = "Endpoint of the Cosmos DB account."
  value       = azurerm_cosmosdb_account.this.endpoint
}

output "mongodb_host" {
  description = "MongoDB host name of the account. Port 10255, TLS required."
  value       = local.mongodb_host
}

output "database_name" {
  description = "Name of the database."
  value       = azurerm_cosmosdb_mongo_database.this.name
}

output "database_id" {
  description = "Resource ID of the database."
  value       = azurerm_cosmosdb_mongo_database.this.id
}

output "database_username" {
  description = "Username of the database owner."
  value       = azurerm_cosmosdb_mongo_user_definition.this.username
}

output "database_password" {
  description = "Password of the database owner."
  sensitive   = true
  value       = local.password
}

output "connection_string" {
  description = "MongoDB connection string of the database, authenticating with the username and password."
  sensitive   = true
  value       = local.connection_string
}

output "managed_identity_name" {
  description = "Name of the managed identity, null when `managed_identity_enabled` is false."
  value       = one(azurerm_user_assigned_identity.this[*].name)
}

output "managed_identity_client_id" {
  description = "Client ID of the managed identity, passed to `DefaultAzureCredential` at runtime. Null when `managed_identity_enabled` is false."
  value       = one(azurerm_user_assigned_identity.this[*].client_id)
}

output "managed_identity_principal_id" {
  description = "Object ID of the managed identity, for role assignments made elsewhere. Null when `managed_identity_enabled` is false."
  value       = one(azurerm_user_assigned_identity.this[*].principal_id)
}

output "managed_identity_role_definition_name" {
  description = "Azure role the managed identity holds on the account, null when `managed_identity_enabled` is false."
  value       = one(azurerm_role_assignment.managed_identity[*].role_definition_name)
}

output "primary_mongodb_connection_string" {
  description = "Account level MongoDB connection string. It carries the account key and bypasses the database user, prefer the connection string above."
  sensitive   = true
  value       = azurerm_cosmosdb_account.this.primary_mongodb_connection_string
}

output "key_vault_id" {
  description = "Resource ID of the Key Vault holding the database secrets, null when `key_vault_enabled` is false."
  value       = one(azurerm_key_vault.this[*].id)
}

output "key_vault_name" {
  description = "Name of the Key Vault, null when `key_vault_enabled` is false."
  value       = one(azurerm_key_vault.this[*].name)
}

output "key_vault_uri" {
  description = "URI of the Key Vault, for example `https://<vault>.vault.azure.net/`. Null when `key_vault_enabled` is false."
  value       = one(azurerm_key_vault.this[*].vault_uri)
}

output "key_vault_password_secret_name" {
  description = "Name of the secret holding the database password, null when `key_vault_enabled` is false."
  value       = one(azurerm_key_vault_secret.database_password[*].name)
}

output "key_vault_connection_string_secret_name" {
  description = "Name of the secret holding the database connection string, null when `key_vault_enabled` is false."
  value       = one(azurerm_key_vault_secret.database_connection_string[*].name)
}
