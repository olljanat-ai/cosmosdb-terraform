output "mongodb_host" {
  description = "MongoDB host name of the account."
  value       = module.cosmosdb.mongodb_host
}

output "account_name" {
  description = "Name of the Cosmos DB account, needed to look the connection string up at runtime."
  value       = module.cosmosdb.name
}

output "resource_group_name" {
  description = "Resource group of the Cosmos DB account."
  value       = azurerm_resource_group.example.name
}

output "app_identity_client_id" {
  description = "Client ID of the read-write identity, for DefaultAzureCredential."
  value       = azurerm_user_assigned_identity.app.client_id
}

output "reporting_identity_client_id" {
  description = "Client ID of the read-only identity, for DefaultAzureCredential."
  value       = azurerm_user_assigned_identity.reporting.client_id
}
