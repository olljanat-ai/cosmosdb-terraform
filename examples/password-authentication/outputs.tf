output "mongodb_host" {
  description = "MongoDB host name of the account."
  value       = module.cosmosdb.mongodb_host
}

output "database_users" {
  description = "Owner credentials and connection string of every database."
  sensitive   = true
  value       = module.cosmosdb.database_users
}
