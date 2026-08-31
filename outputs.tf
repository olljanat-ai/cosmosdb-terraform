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

output "database_ids" {
  description = "Resource ID of every created database, keyed by database name."
  value       = { for name, db in azurerm_cosmosdb_mongo_database.this : name => db.id }
}

output "database_users" {
  description = "Owner credentials and connection string of every database that has a user of its own, keyed by database name."
  sensitive   = true
  value = {
    for name, user in azurerm_cosmosdb_mongo_user_definition.this : name => {
      username = user.username
      password = local.passwords[name]
      connection_string = join("", [
        "mongodb://${local.uri_escaped_usernames[name]}:${local.uri_escaped_passwords[name]}@${local.mongodb_host}:10255/${name}",
        "?ssl=true&replicaSet=globaldb&retrywrites=false&maxIdleTimeMS=120000",
        "&authMechanism=SCRAM-SHA-256&authSource=${name}&appName=@${azurerm_cosmosdb_account.this.name}@",
      ])
    }
  }
}

output "entra_id_identities" {
  description = "Client ID, principal ID and granted role of every managed identity created for this environment, keyed by identity name."
  value = {
    for name, identity in azurerm_user_assigned_identity.this : name => {
      client_id            = identity.client_id
      principal_id         = identity.principal_id
      role_definition_name = local.identities[name].role_definition_name
    }
  }
}

output "entra_id_role_assignment_ids" {
  description = "Resource ID of every Entra ID role assignment on the account."
  value       = { for key, assignment in azurerm_role_assignment.entra_id : key => assignment.id }
}

output "primary_mongodb_connection_string" {
  description = "Account level MongoDB connection string. It carries the account key and grants access to every database, prefer the per-database users."
  sensitive   = true
  value       = azurerm_cosmosdb_account.this.primary_mongodb_connection_string
}
