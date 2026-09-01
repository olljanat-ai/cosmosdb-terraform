provider "azurerm" {
  features {}
}

locals {
  username = coalesce(var.database_username, var.database_name)
  password = var.database_password != null ? var.database_password : random_password.this[0].result

  capabilities = distinct(concat(
    # Mongo RBAC is what makes the database scoped user below possible, so it is
    # always on rather than a choice.
    ["EnableMongo", "EnableMongoRoleBasedAccessControl"],
    var.additional_capabilities,
  ))

  geo_locations = concat([var.location], var.secondary_locations)

  automatic_failover_enabled = coalesce(var.automatic_failover_enabled, length(var.secondary_locations) > 0)

  mongodb_host = "${var.cosmosdb_account_name}.mongo.cosmos.azure.com"

  # `urlencode` renders a space as "+", which a MongoDB driver reads literally
  # in the userinfo part of a connection string. Everything else it emits is
  # already correct percent encoding, and a literal "+" comes back as "%2B",
  # so a plain replace is unambiguous.
  uri_escaped_username = replace(urlencode(local.username), "+", "%20")
  uri_escaped_password = replace(urlencode(local.password), "+", "%20")

  # Built once here, because both the output and the Key Vault secret need it.
  connection_string = join("", [
    "mongodb://${local.uri_escaped_username}:${local.uri_escaped_password}@${local.mongodb_host}:10255/${var.database_name}",
    "?ssl=true&replicaSet=globaldb&retrywrites=false&maxIdleTimeMS=120000",
    "&authMechanism=SCRAM-SHA-256&authSource=${var.database_name}&appName=@${var.cosmosdb_account_name}@",
  ])

  managed_identity_name = coalesce(var.managed_identity_name, "id-${var.cosmosdb_account_name}")

  # A Key Vault name is 3-24 characters, an account name is up to 44, so the
  # derived name is prefixed and truncated. Like the account name it is part of
  # a public DNS name, so set `key_vault_name` when truncation is not unique
  # enough. Consecutive hyphens are not allowed in a vault name either.
  key_vault_prefixed_name  = replace("kv-${var.cosmosdb_account_name}", "/-+/", "-")
  key_vault_generated_name = trimsuffix(substr(local.key_vault_prefixed_name, 0, min(24, length(local.key_vault_prefixed_name))), "-")
  key_vault_name           = coalesce(var.key_vault_name, local.key_vault_generated_name)

  # A secret name accepts letters, digits and hyphens only, a database name is
  # not that restricted.
  key_vault_secret_name = replace(var.database_name, "/[^0-9A-Za-z-]/", "-")

  # Keys stay known at plan time, the principal ID of a fresh identity does not.
  key_vault_readers = merge(
    {
      for id in var.key_vault_reader_principal_ids : "principal/${id}" => {
        principal_id   = id
        principal_type = null
      }
    },
    var.key_vault_grant_managed_identity_access ? {
      for principal_id in azurerm_user_assigned_identity.this[*].principal_id : "managed-identity" => {
        principal_id = principal_id
        # Set explicitly, a freshly created identity is not replicated yet when
        # the assignment is made.
        principal_type = "ServicePrincipal"
      }
    } : {},
  )
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_cosmosdb_account" "this" {
  name                = var.cosmosdb_account_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
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
}

# The one database of the account.
resource "azurerm_cosmosdb_mongo_database" "this" {
  name                = var.database_name
  resource_group_name = azurerm_cosmosdb_account.this.resource_group_name
  account_name        = azurerm_cosmosdb_account.this.name
  throughput          = var.database_throughput

  dynamic "autoscale_settings" {
    for_each = var.database_max_throughput == null ? [] : [var.database_max_throughput]

    content {
      max_throughput = autoscale_settings.value
    }
  }
}

# Only generated when no password was supplied.
resource "random_password" "this" {
  count = var.database_password == null ? 1 : 0

  length      = 32
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1

  # Kept to characters that survive a connection string without percent encoding.
  override_special = "-_.~"
}

# Way in number one: username and password. The user definition is scoped to the
# single database and inherits `dbOwner` in it.
resource "azurerm_cosmosdb_mongo_user_definition" "this" {
  cosmos_mongo_database_id = azurerm_cosmosdb_mongo_database.this.id
  username                 = local.username
  password                 = local.password
  inherited_role_names     = var.database_role_names
}

# Way in number two: a managed identity that authenticates with its own Entra ID
# token and reads the account connection string through the control plane.
resource "azurerm_user_assigned_identity" "this" {
  count = var.managed_identity_enabled ? 1 : 0

  name                = local.managed_identity_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "managed_identity" {
  count = length(azurerm_user_assigned_identity.this)

  scope                = azurerm_cosmosdb_account.this.id
  role_definition_name = var.managed_identity_role_definition_name
  principal_id         = azurerm_user_assigned_identity.this[0].principal_id
  principal_type       = "ServicePrincipal"
}

data "azurerm_client_config" "current" {}

# The password and the connection string built from it are written here, so that
# an application reads them from the vault instead of from the Terraform state
# or an output.
resource "azurerm_key_vault" "this" {
  count = var.key_vault_enabled ? 1 : 0

  name                = local.key_vault_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = var.key_vault_sku_name

  # Access is granted with Azure role assignments, access policies are the
  # legacy model and cannot be mixed with them.
  rbac_authorization_enabled    = true
  purge_protection_enabled      = var.key_vault_purge_protection_enabled
  soft_delete_retention_days    = var.key_vault_soft_delete_retention_days
  public_network_access_enabled = var.key_vault_public_network_access_enabled
  tags                          = var.tags

  lifecycle {
    precondition {
      condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", local.key_vault_name)) && !can(regex("--", local.key_vault_name))
      error_message = "Key Vault name `${local.key_vault_name}` is invalid. It must be 3-24 characters of letters, digits and single hyphens, and start with a letter. Set `key_vault_name` explicitly when the name derived from `cosmosdb_account_name` does not fit."
    }
  }
}

# Terraform writes the secrets with the identity that runs the apply, and under
# RBAC that identity needs a data plane role of its own on the vault.
resource "azurerm_role_assignment" "key_vault_deployer" {
  count = var.key_vault_enabled && var.key_vault_grant_deployer_access ? 1 : 0

  scope                = azurerm_key_vault.this[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# A fresh role assignment takes a while to reach the Key Vault data plane, and
# until it does every secret write comes back as 403. Only waited through on
# create, so it costs nothing on the applies after the first one.
resource "time_sleep" "key_vault_rbac" {
  count = length(azurerm_role_assignment.key_vault_deployer)

  create_duration = var.key_vault_rbac_propagation_delay

  triggers = {
    role_assignment_id = azurerm_role_assignment.key_vault_deployer[0].id
  }
}

# The managed identity reads the same credentials from the vault, which is how a
# workload gets them without a password baked into its configuration.
resource "azurerm_role_assignment" "key_vault_secrets_user" {
  for_each = var.key_vault_enabled ? local.key_vault_readers : {}

  scope                = azurerm_key_vault.this[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type
}

resource "azurerm_key_vault_secret" "database_password" {
  count = var.key_vault_enabled ? 1 : 0

  name         = "${local.key_vault_secret_name}-password"
  value        = local.password
  key_vault_id = azurerm_key_vault.this[0].id
  content_type = "password"
  tags         = var.tags

  depends_on = [
    azurerm_cosmosdb_mongo_user_definition.this,
    time_sleep.key_vault_rbac,
  ]
}

resource "azurerm_key_vault_secret" "database_connection_string" {
  count = var.key_vault_enabled ? 1 : 0

  name         = "${local.key_vault_secret_name}-connection-string"
  value        = local.connection_string
  key_vault_id = azurerm_key_vault.this[0].id
  content_type = "connection-string"
  tags         = var.tags

  depends_on = [
    azurerm_cosmosdb_mongo_user_definition.this,
    time_sleep.key_vault_rbac,
  ]
}

# Off by default: this one carries the account key, which bypasses the database
# user entirely.
resource "azurerm_key_vault_secret" "primary_mongodb_connection_string" {
  count = var.key_vault_enabled && var.key_vault_store_account_connection_string ? 1 : 0

  name         = "cosmosdb-primary-connection-string"
  value        = azurerm_cosmosdb_account.this.primary_mongodb_connection_string
  key_vault_id = azurerm_key_vault.this[0].id
  content_type = "connection-string"
  tags         = var.tags

  depends_on = [time_sleep.key_vault_rbac]
}
