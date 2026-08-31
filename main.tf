provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

locals {
  # `databases` is a list for convenience, but resources are keyed by database name
  # so that reordering the list does not recreate anything.
  databases = { for db in var.databases : db.name => db }

  # Databases that get an owner of their own. The rest are reached through Entra ID.
  users = { for name, db in local.databases : name => db if db.create_user }

  identities = { for i in var.entra_id_identities : i.name => i }

  capabilities = distinct(concat(
    ["EnableMongo"],
    var.mongo_rbac_enabled ? ["EnableMongoRoleBasedAccessControl"] : [],
    var.additional_capabilities,
  ))

  geo_locations = [
    for index, location in concat([var.location], var.secondary_locations) : {
      location          = location
      failover_priority = index
      zone_redundant    = var.zone_redundant
    }
  ]

  automatic_failover_enabled = coalesce(var.automatic_failover_enabled, length(var.secondary_locations) > 0)

  # Identities created here and principals that already exist end up in the same
  # set of role assignments. Keys stay known at plan time, values do not have to be.
  #
  # The Cosmos DB module does not pass `principal_type` through to
  # `azurerm_role_assignment`, so a fresh service principal is covered with
  # `skip_service_principal_aad_check` instead, which is what that flag is for.
  cosmosdb_role_assignments = merge(
    {
      for name, identity in local.identities : "identity/${name}" => {
        role_definition_id_or_name       = identity.role_definition_name
        principal_id                     = module.user_assigned_identity[name].principal_id
        skip_service_principal_aad_check = true
      }
    },
    {
      for a in var.entra_id_access : "principal/${a.principal_id}|${a.role_definition_name}" => {
        role_definition_id_or_name       = a.role_definition_name
        principal_id                     = a.principal_id
        skip_service_principal_aad_check = a.principal_type == "ServicePrincipal"
      }
    },
  )

  passwords = {
    for name, db in local.users :
    name => db.password != null ? db.password : random_password.this[name].result
  }

  mongodb_host = "${var.cosmosdb_account_name}.mongo.cosmos.azure.com"

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

  # Built once here, because both the output and the Key Vault secret need it.
  connection_strings = {
    for name, db in local.users :
    name => join("", [
      "mongodb://${local.uri_escaped_usernames[name]}:${local.uri_escaped_passwords[name]}@${local.mongodb_host}:10255/${name}",
      "?ssl=true&replicaSet=globaldb&retrywrites=false&maxIdleTimeMS=120000",
      "&authMechanism=SCRAM-SHA-256&authSource=${name}&appName=@${var.cosmosdb_account_name}@",
    ])
  }

  # A Key Vault name is 3-24 characters, an account name is up to 44, so the
  # derived name is prefixed and truncated. Like the account name it is part of
  # a public DNS name, so set `key_vault_name` when truncation is not unique
  # enough. Consecutive hyphens are not allowed in a vault name either.
  key_vault_prefixed_name  = replace("kv-${var.cosmosdb_account_name}", "/-+/", "-")
  key_vault_generated_name = trimsuffix(substr(local.key_vault_prefixed_name, 0, min(24, length(local.key_vault_prefixed_name))), "-")
  key_vault_name           = coalesce(var.key_vault_name, local.key_vault_generated_name)

  # A secret name accepts letters, digits and hyphens only, a database name is
  # not that restricted.
  key_vault_secret_names = {
    for name, db in local.users : name => replace(name, "/[^0-9A-Za-z-]/", "-")
  }

  # Terraform writes the secrets with the identity that runs the apply, and under
  # RBAC that identity needs a data plane role of its own on the vault. Reading a
  # secret back is a second role, and it is scoped to the vault and not to a
  # single secret, so a principal listed in `key_vault_secrets_access` reads every
  # database password in it.
  key_vault_role_assignments = merge(
    var.key_vault_grant_deployer_access ? {
      deployer = {
        role_definition_id_or_name = "Key Vault Secrets Officer"
        principal_id               = data.azurerm_client_config.current.object_id
        description                = "Lets the identity running Terraform write the database secrets."
      }
    } : {},
    {
      for a in var.key_vault_secrets_access : "secrets-user/${a.principal_id}" => {
        role_definition_id_or_name = "Key Vault Secrets User"
        principal_id               = a.principal_id
        principal_type             = a.principal_type
      }
    },
  )

  # The map keys are the handles the module knows the secrets by. `secrets` holds
  # the metadata and `secrets_value` the values, split because a value is
  # sensitive and a `for_each` key cannot be.
  key_vault_secrets = merge(
    {
      for name, db in local.users : "${name}-password" => {
        name         = "${local.key_vault_secret_names[name]}-password"
        content_type = "password"
        tags         = var.tags
      }
    },
    {
      for name, db in local.users : "${name}-connection-string" => {
        name         = "${local.key_vault_secret_names[name]}-connection-string"
        content_type = "connection-string"
        tags         = var.tags
      }
    },
    # Off by default: this one carries the account key and reaches every database,
    # and anyone who can read a secret in the vault can read this one too.
    var.key_vault_store_account_connection_string ? {
      account-connection-string = {
        name         = "cosmosdb-primary-connection-string"
        content_type = "connection-string"
        tags         = var.tags
      }
    } : {},
  )

  key_vault_secret_values = merge(
    { for name, password in local.passwords : "${name}-password" => password },
    { for name, connection_string in local.connection_strings : "${name}-connection-string" => connection_string },
    var.key_vault_store_account_connection_string ? {
      account-connection-string = module.cosmosdb_account.cosmosdb_mongodb_connection_strings.primary_mongodb_connection_string
    } : {},
  )
}

module "resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "0.4.0"

  location         = var.location
  name             = var.resource_group_name
  enable_telemetry = var.enable_telemetry
  tags             = var.tags
}

# One account for the whole environment. Every database below lives in it: the
# module creates the account and the databases together, and turns to MongoDB as
# soon as `mongo_databases` is not empty.
module "cosmosdb_account" {
  source  = "Azure/avm-res-documentdb-databaseaccount/azurerm"
  version = "0.10.0"

  location            = module.resource_group.location
  name                = var.cosmosdb_account_name
  resource_group_name = module.resource_group.name

  mongo_server_version = var.mongo_server_version
  mongo_databases = {
    for name, db in local.databases : name => {
      name               = db.name
      throughput         = db.throughput
      autoscale_settings = db.max_throughput == null ? null : { max_throughput = db.max_throughput }
    }
  }

  capabilities = [for capability in local.capabilities : { name = capability }]

  consistency_policy = {
    consistency_level = var.consistency_level
    # Only read by the module when the level is `BoundedStaleness`, and then
    # they have to be inside the range Azure accepts, so fall back to the
    # module's own defaults rather than to null.
    max_interval_in_seconds = coalesce(var.max_interval_in_seconds, 5)
    max_staleness_prefix    = coalesce(var.max_staleness_prefix, 100)
  }

  geo_locations              = local.geo_locations
  automatic_failover_enabled = local.automatic_failover_enabled
  backup                     = var.backup

  public_network_access_enabled = var.public_network_access_enabled
  ip_range_filter               = var.ip_range_filter

  # Entra ID principals authenticate with their own token and read the account
  # connection string through the control plane instead of holding a password.
  role_assignments = local.cosmosdb_role_assignments

  enable_telemetry = var.enable_telemetry
  tags             = var.tags
}

module "user_assigned_identity" {
  source   = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"
  version  = "0.5.2"
  for_each = local.identities

  location            = module.resource_group.location
  name                = each.value.name
  resource_group_name = module.resource_group.name
  enable_telemetry    = var.enable_telemetry
  tags                = var.tags
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
#
# There is no Azure Verified Module for a Mongo RBAC user definition, and the
# Cosmos DB module does not manage one either, so this stays a plain resource.
resource "azurerm_cosmosdb_mongo_user_definition" "this" {
  for_each = local.users

  cosmos_mongo_database_id = module.cosmosdb_account.mongo_databases[each.key].id
  username                 = coalesce(each.value.username, each.value.name)
  password                 = local.passwords[each.key]
  inherited_role_names     = each.value.role_names
}

# The generated passwords and the connection strings built from them are written
# here, so that an application reads them from the vault instead of from the
# Terraform state or an output.
#
# A fresh role assignment takes a while to reach the Key Vault data plane, and
# until it does every secret write comes back as 403. The module waits that out
# through `wait_for_rbac_before_secret_operations`, on create only.
module "key_vault" {
  source  = "Azure/avm-res-keyvault-vault/azurerm"
  version = "0.11.0"
  count   = var.key_vault_enabled ? 1 : 0

  location            = module.resource_group.location
  name                = local.key_vault_name
  resource_group_name = module.resource_group.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = var.key_vault_sku_name

  purge_protection_enabled      = var.key_vault_purge_protection_enabled
  soft_delete_retention_days    = var.key_vault_soft_delete_retention_days
  public_network_access_enabled = var.key_vault_public_network_access_enabled

  # Access is granted with Azure role assignments, `legacy_access_policies_enabled`
  # stays false so the module keeps RBAC authorization on.
  role_assignments = local.key_vault_role_assignments

  secrets       = local.key_vault_secrets
  secrets_value = local.key_vault_secret_values

  wait_for_rbac_before_secret_operations = {
    create = var.key_vault_rbac_propagation_delay
  }

  enable_telemetry = var.enable_telemetry
  tags             = var.tags

  # A password is only worth publishing once the user it belongs to exists.
  depends_on = [azurerm_cosmosdb_mongo_user_definition.this]
}
