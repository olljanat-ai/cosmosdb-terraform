output "resource_group_name" {
  description = "Name of the resource group holding the environment."
  value       = azurerm_resource_group.this.name
}

output "account_id" {
  description = "Resource ID of the Cosmos DB account."
  value       = module.cosmosdb.resource_id
}

output "account_name" {
  description = "Name of the Cosmos DB account."
  value       = module.cosmosdb.name
}

output "endpoint" {
  description = "Endpoint of the account, which is what a client is pointed at. It carries no credential: the client authenticates with a token."
  value       = module.cosmosdb.endpoint
}

output "database_names" {
  description = "Names of the databases created in the account."
  value       = sort(keys(var.databases))
}

output "database_identities" {
  description = "The identity created for each database, keyed by database name. `client_id` is what a workload configures to authenticate as it, `principal_id` is what appears in the role assignment, and `resource_id` is what an Azure resource references to attach it."
  value = {
    for name, identity in azurerm_user_assigned_identity.database : name => {
      name         = identity.name
      client_id    = identity.client_id
      principal_id = identity.principal_id
      resource_id  = identity.id
      tenant_id    = identity.tenant_id
    }
  }
}

output "database_scopes" {
  description = "The data plane scope of each database, keyed by database name. This is the path a role assignment is narrowed to."
  value       = local.database_scopes
}

output "local_authentication_disabled" {
  description = "Whether key based authentication is off on the account. Always true here, and the reason there is no key and no connection string among these outputs."
  value       = true
}
