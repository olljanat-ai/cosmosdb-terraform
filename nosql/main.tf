provider "azurerm" {
  features {}
}

locals {
  # Built-in data plane roles of the account. The identifiers are the same in
  # every Cosmos DB account, only the account part of the resource ID differs.
  # `...0001` reads data, `...0002` reads and writes it. Both are data plane
  # only: neither one creates a database or a container, which is why Terraform
  # keeps doing that over the control plane.
  data_reader_role_definition_id      = "${module.cosmosdb.resource_id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001"
  data_contributor_role_definition_id = "${module.cosmosdb.resource_id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"

  # A data plane assignment is scoped by path. `/dbs/<name>` is one database and
  # everything in it, and the account resource ID on its own is every database
  # of the account.
  account_scope       = module.cosmosdb.resource_id
  database_scopes     = { for name in keys(var.databases) : name => "${module.cosmosdb.resource_id}/dbs/${name}" }
  geo_locations       = concat([var.location], var.secondary_locations)
  database_identities = { for name, database in var.databases : name => database if database.identity.enabled }

  # The `sql_databases` input of the module, built from `databases` so that the
  # databases, their identities and their role assignments all come from one
  # place.
  sql_databases = {
    for name, database in var.databases : name => {
      name               = name
      throughput         = database.throughput
      autoscale_settings = database.max_throughput == null ? null : { max_throughput = database.max_throughput }

      containers = {
        for container_name, container in database.containers : container_name => {
          name                  = container_name
          partition_key_paths   = container.partition_key_paths
          partition_key_version = container.partition_key_version
          throughput            = container.throughput
          default_ttl           = container.default_ttl
          autoscale_settings    = container.max_throughput == null ? null : { max_throughput = container.max_throughput }
          unique_keys           = [for paths in container.unique_key_paths : { paths = toset(paths) }]
        }
      }
    }
  }

  # Federated credentials of the per database identities, flattened into one map
  # keyed `<database>/<credential>`.
  federated_credentials = {
    for item in flatten([
      for name, database in local.database_identities : [
        for credential_name, credential in database.identity.federated_credentials : {
          key      = "${name}/${credential_name}"
          database = name
          name     = credential_name
          issuer   = credential.issuer
          subject  = credential.subject
          audience = credential.audience
        }
      ]
    ]) : item.key => item
  }

  # Principals that were handed in rather than created here, one entry per
  # principal and database.
  database_principals = {
    for item in flatten([
      for name, database in var.databases : concat(
        [for principal_id in database.contributor_principal_ids : {
          key          = "${name}/contributor/${principal_id}"
          database     = name
          principal_id = principal_id
          contributor  = true
        }],
        [for principal_id in database.reader_principal_ids : {
          key          = "${name}/reader/${principal_id}"
          database     = name
          principal_id = principal_id
          contributor  = false
        }],
      )
    ]) : item.key => item
  }

  account_principals = merge(
    { for principal_id in var.account_contributor_principal_ids : "contributor/${principal_id}" => {
      principal_id = principal_id
      contributor  = true
    } },
    { for principal_id in var.account_reader_principal_ids : "reader/${principal_id}" => {
      principal_id = principal_id
      contributor  = false
    } },
  )
}

# An account with public access off and no private endpoint is reachable from
# nowhere. That is a legitimate intermediate state, when the endpoint is created
# elsewhere, so it is a warning rather than an error.
check "account_is_reachable" {
  assert {
    condition     = var.public_network_access_enabled || var.private_endpoint_subnet_id != null
    error_message = "The account has neither public network access nor a private endpoint, so nothing can reach it. Set `private_endpoint_subnet_id`, or `public_network_access_enabled = true` with `ip_range_filter`."
  }
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# Azure Verified Module for `Microsoft.DocumentDB/databaseAccounts`. It creates
# the account, the databases and the containers, and it defaults
# `local_authentication_disabled` to true, which is the setting that takes the
# account keys out of service. The module applies that setting only when the
# account has at least one SQL database, which is why `databases` may not be
# empty here.
module "cosmosdb" {
  source  = "Azure/avm-res-documentdb-databaseaccount/azurerm"
  version = "0.10.0"

  location            = var.location
  name                = var.account_name
  resource_group_name = azurerm_resource_group.this.name

  # No keys, no connection strings, no local authentication. Entra ID and the
  # data plane role assignments below are the whole access story.
  local_authentication_disabled      = true
  access_key_metadata_writes_enabled = false

  sql_databases = local.sql_databases

  geo_locations = toset([
    for index, location in local.geo_locations : {
      location          = location
      failover_priority = index
      zone_redundant    = var.zone_redundant
    }
  ])
  automatic_failover_enabled = coalesce(var.automatic_failover_enabled, length(var.secondary_locations) > 0)

  consistency_policy = {
    consistency_level       = var.consistency_level
    max_interval_in_seconds = coalesce(var.max_interval_in_seconds, 5)
    max_staleness_prefix    = coalesce(var.max_staleness_prefix, 100)
  }

  public_network_access_enabled = var.public_network_access_enabled
  ip_range_filter               = toset(var.ip_range_filter)

  private_endpoints = var.private_endpoint_subnet_id == null ? {} : {
    primary = {
      # `Sql` is the private link sub resource of the NoSQL API. The account
      # publishes one endpoint per region behind it.
      subresource_name              = "Sql"
      subnet_resource_id            = var.private_endpoint_subnet_id
      private_dns_zone_resource_ids = toset(var.private_dns_zone_ids)
    }
  }

  diagnostic_settings = var.log_analytics_workspace_id == null ? {} : {
    all = {
      name                  = "diag-${var.account_name}"
      workspace_resource_id = var.log_analytics_workspace_id
    }
  }

  enable_telemetry = var.enable_telemetry
  tags             = var.tags
}

# One identity per database, which is what makes the access of a workload
# specific to its own database rather than to the account.
resource "azurerm_user_assigned_identity" "database" {
  for_each = local.database_identities

  name                = coalesce(each.value.identity.name, "id-${var.account_name}-${each.key}")
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

# What turns a managed identity into a workload identity: a trust between the
# identity and an external OIDC issuer, so that a Kubernetes service account or
# a pipeline exchanges its own token for one of this identity.
resource "azurerm_federated_identity_credential" "database" {
  for_each = local.federated_credentials

  name                      = each.value.name
  user_assigned_identity_id = azurerm_user_assigned_identity.database[each.value.database].id
  issuer                    = each.value.issuer
  subject                   = each.value.subject
  audience                  = each.value.audience
}

# The identity of a database reads and writes that database, and nothing else in
# the account. This is the data plane assignment, which is a different thing
# from an Azure role assignment: an Azure role grants management of the account,
# this grants the documents inside one database.
resource "azurerm_cosmosdb_sql_role_assignment" "database_identity" {
  for_each = local.database_identities

  account_name        = module.cosmosdb.name
  resource_group_name = azurerm_resource_group.this.name
  role_definition_id  = local.data_contributor_role_definition_id
  principal_id        = azurerm_user_assigned_identity.database[each.key].principal_id
  scope               = local.database_scopes[each.key]
}

# Principals handed in per database: another workload's identity, or the group
# that operates that one database.
resource "azurerm_cosmosdb_sql_role_assignment" "database_principal" {
  for_each = local.database_principals

  account_name        = module.cosmosdb.name
  resource_group_name = azurerm_resource_group.this.name
  role_definition_id  = each.value.contributor ? local.data_contributor_role_definition_id : local.data_reader_role_definition_id
  principal_id        = each.value.principal_id
  scope               = local.database_scopes[each.value.database]
}

# Account wide access, which reaches every database. Empty by default: the point
# of this configuration is that access stops at one database.
resource "azurerm_cosmosdb_sql_role_assignment" "account_principal" {
  for_each = local.account_principals

  account_name        = module.cosmosdb.name
  resource_group_name = azurerm_resource_group.this.name
  role_definition_id  = each.value.contributor ? local.data_contributor_role_definition_id : local.data_reader_role_definition_id
  principal_id        = each.value.principal_id
  scope               = local.account_scope
}
