output "resource_group_name" {
  description = "Name of the resource group holding the environment."
  value       = azurerm_resource_group.this.name
}

output "cluster_id" {
  description = "Resource ID of the MongoDB vCore cluster."
  value       = module.mongo_cluster.resource_id
}

output "cluster_name" {
  description = "Name of the MongoDB vCore cluster."
  value       = module.mongo_cluster.mongo_cluster_name
}

output "mongodb_host" {
  description = "Host name of the cluster. TLS required."
  value       = local.mongodb_host
}

output "connection_string_template" {
  description = "MongoDB connection string of the cluster, authenticating with a Microsoft Entra ID token. `<client-id>` is filled in by the workload with the client ID of the identity it authenticates as, which is the one part of the string this configuration cannot know."
  value       = local.connection_string_template
}

output "entra_administrator_object_ids" {
  description = "Object IDs of the principals that were granted access to the cluster, keyed by the name they were given in `entra_administrators`."
  value       = { for name, principal in var.entra_administrators : name => principal.object_id }
}

output "private_endpoint_ids" {
  description = "Resource IDs of the private endpoints created for the cluster, empty when `private_endpoint_subnet_id` is unset."
  value       = { for key, endpoint in module.mongo_cluster.private_endpoints : key => endpoint.id }
}

output "native_authentication_enabled" {
  description = "Whether username and password authentication is allowed on the cluster. False means Entra ID is the only way in and the generated administrator password below cannot be used."
  value       = var.native_authentication_enabled
}

output "native_administrator_username" {
  description = "Username of the native administrator account. Only usable when `native_authentication_enabled` is true."
  value       = local.native_administrator_login
}

output "native_administrator_password" {
  description = "Password of the native administrator account. Only usable when `native_authentication_enabled` is true, and generated rather than stored in a vault either way."
  sensitive   = true
  value       = random_password.native_administrator.result
}
