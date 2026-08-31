output "id" {
  description = "Resource ID of the Cosmos DB account."
  value       = azurerm_cosmosdb_account.this.id
}

output "name" {
  description = "Name of the Cosmos DB account."
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
  description = "Per-database owner credentials and connection string, keyed by database name. Empty when `create_database_users` is false."
  sensitive   = true
  value = {
    for name, user in azurerm_cosmosdb_mongo_user_definition.this : name => {
      username = user.username
      password = local.passwords[name]
      connection_string = join("", [
        "mongodb://${urlencode(user.username)}:${urlencode(local.passwords[name])}@${local.mongodb_host}:10255/${name}",
        "?ssl=true&replicaSet=globaldb&retrywrites=false&maxIdleTimeMS=120000",
        "&authMechanism=SCRAM-SHA-256&authSource=${name}&appName=@${azurerm_cosmosdb_account.this.name}@",
      ])
    }
  }
}

output "primary_mongodb_connection_string" {
  description = "Account level MongoDB connection string. It carries the account key and grants access to every database, prefer the per-database users."
  sensitive   = true
  value       = azurerm_cosmosdb_account.this.primary_mongodb_connection_string
}

output "entra_id_role_assignment_ids" {
  description = "Resource ID of every Entra ID role assignment, keyed by `<principal_id>|<role_definition_name>`."
  value       = { for key, assignment in azurerm_role_assignment.entra_id : key => assignment.id }
}
