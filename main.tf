locals {
  # `databases` is a list for convenience, but resources are keyed by database name
  # so that reordering the list does not recreate anything.
  databases = { for db in var.databases : db.name => db }

  users = var.create_database_users ? local.databases : {}

  entra_id_access = {
    for a in var.entra_id_access : "${a.principal_id}|${a.role_definition_name}" => a
  }

  capabilities = distinct(concat(
    ["EnableMongo"],
    var.mongo_rbac_enabled ? ["EnableMongoRoleBasedAccessControl"] : [],
    var.additional_capabilities,
  ))

  geo_locations = concat([var.location], var.secondary_locations)

  automatic_failover_enabled = coalesce(var.automatic_failover_enabled, length(var.secondary_locations) > 0)

  passwords = {
    for name, db in local.users :
    name => db.password != null ? db.password : random_password.this[name].result
  }

  mongodb_host = "${var.name}.mongo.cosmos.azure.com"

  # `urlencode` renders a space as "+", which a MongoDB driver reads literally
  # in the userinfo part of a connection string. Everything else it emits is
  # already correct percent encoding, and a literal "+" comes back as "%2B",
  # so a plain replace is unambiguous.
  uri_escaped_usernames = {
    for name, db in local.users :
    name => replace(urlencode(coalesce(db.username, db.name)), "+", "%20")
  }

  uri_escaped_passwords = {
    for name, password in local.passwords : name => replace(urlencode(password), "+", "%20")
  }
}

resource "azurerm_cosmosdb_account" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  offer_type          = "Standard"
  kind                = "MongoDB"

  mongo_server_version          = var.mongo_server_version
  minimal_tls_version           = "Tls12"
  automatic_failover_enabled    = local.automatic_failover_enabled
  public_network_access_enabled = var.public_network_access_enabled
  ip_range_filter               = var.ip_range_filter
  tags                          = var.tags

  dynamic "capabilities" {
    for_each = local.capabilities

    content {
      name = capabilities.value
    }
  }

  consistency_policy {
    consistency_level       = var.consistency_level
    max_interval_in_seconds = var.max_interval_in_seconds
    max_staleness_prefix    = var.max_staleness_prefix
  }

  dynamic "geo_location" {
    for_each = local.geo_locations

    content {
      location          = geo_location.value
      failover_priority = geo_location.key
      zone_redundant    = var.zone_redundant
    }
  }

  lifecycle {
    precondition {
      condition     = var.mongo_rbac_enabled || !var.create_database_users
      error_message = "`create_database_users` requires `mongo_rbac_enabled` to be true, per-database users are a Mongo RBAC feature."
    }
  }
}

resource "azurerm_cosmosdb_mongo_database" "this" {
  for_each = local.databases

  name                = each.value.name
  resource_group_name = azurerm_cosmosdb_account.this.resource_group_name
  account_name        = azurerm_cosmosdb_account.this.name
  throughput          = each.value.throughput

  dynamic "autoscale_settings" {
    for_each = each.value.max_throughput == null ? [] : [each.value.max_throughput]

    content {
      max_throughput = autoscale_settings.value
    }
  }
}

# Only generated for databases that did not come with a password of their own.
resource "random_password" "this" {
  for_each = { for name, db in local.users : name => db if db.password == null }

  length      = 32
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1

  # Kept to characters that survive a connection string without percent encoding.
  override_special = "-_.~"
}

# One user per database, owning that database and nothing else: the user
# definition is scoped to a single database and inherits `dbOwner` in it.
resource "azurerm_cosmosdb_mongo_user_definition" "this" {
  for_each = local.users

  cosmos_mongo_database_id = azurerm_cosmosdb_mongo_database.this[each.key].id
  username                 = coalesce(each.value.username, each.value.name)
  password                 = local.passwords[each.key]
  inherited_role_names     = each.value.role_names
}

# Entra ID principals authenticate with their own token and read the account
# connection string through the control plane instead of holding a password.
resource "azurerm_role_assignment" "entra_id" {
  for_each = local.entra_id_access

  scope                = azurerm_cosmosdb_account.this.id
  role_definition_name = each.value.role_definition_name
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type
}
