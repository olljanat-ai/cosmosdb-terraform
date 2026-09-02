provider "azurerm" {
  features {}
}

locals {
  # The name of the native administrator account. The account exists because the
  # cluster API insists on one, and it is named after what it is: an account
  # nobody can authenticate as while native authentication is off. The module
  # underneath requires 4-31 characters, starting with a letter.
  native_administrator_login = "nativeauthdisabled"

  # Entra ID only. `NativeAuth` is the username and password mechanism of the
  # cluster, and leaving it out of `allowedModes` is what turns password
  # authentication off on the data plane.
  allowed_auth_modes = var.native_authentication_enabled ? ["MicrosoftEntraID", "NativeAuth"] : ["MicrosoftEntraID"]

  # The user resource is named after the object ID of the principal, and `root`
  # on `admin` is the only role the cluster user API accepts today. See the
  # "Authorization" section of the README.
  entra_users = {
    for name, principal in var.entra_administrators : principal.object_id => {
      roles = [{
        db   = "admin"
        role = "root"
      }]
      identity_provider = {
        type = "MicrosoftEntraID"
        properties = {
          principal_type = principal.principal_type
        }
      }
    }
  }

  mongodb_host = "${var.cluster_name}.global.mongocluster.cosmos.azure.com"

  # The username of an `MONGODB-OIDC` connection is the *client* ID of the
  # identity that connects, which is not known here: one cluster serves several
  # of them, and a user is identified by its object ID rather than its client
  # ID. So this is a template with the one field the workload fills in itself.
  connection_string_template = join("", [
    "mongodb+srv://<client-id>@${local.mongodb_host}/",
    "?tls=true&authMechanism=MONGODB-OIDC&retrywrites=false&maxIdleTimeMS=120000",
  ])

  # One private endpoint, in the subnet given. The module underneath takes a map
  # of them, which is more than this configuration needs.
  private_endpoints = var.private_endpoint_subnet_id == null ? {} : {
    primary = {
      subnet_resource_id            = var.private_endpoint_subnet_id
      private_dns_zone_resource_ids = toset(var.private_dns_zone_ids)
    }
  }

  diagnostic_settings = var.log_analytics_workspace_id == null ? {} : {
    all = {
      name                  = "diag-${var.cluster_name}"
      workspace_resource_id = var.log_analytics_workspace_id
    }
  }
}

# A cluster with public access off and no private endpoint is reachable from
# nowhere. That is a legitimate intermediate state, when the endpoint is created
# elsewhere, so it is a warning rather than an error.
check "cluster_is_reachable" {
  assert {
    condition     = var.public_network_access_enabled || var.private_endpoint_subnet_id != null
    error_message = "The cluster has neither public network access nor a private endpoint, so nothing can reach it. Set `private_endpoint_subnet_id`, or `public_network_access_enabled = true` with `firewall_rules`."
  }
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# The cluster API takes an administrator username and password whether or not
# native authentication is allowed, and the module underneath requires both, so
# a password is generated here and never written anywhere else: no output, no
# Key Vault, no secret. While `native_authentication_enabled` is false the
# credential cannot be used to connect at all, because the cluster does not
# accept the mechanism it belongs to. It does live in the Terraform state, see
# the "Secrets in state" section of the README.
resource "random_password" "native_administrator" {
  length      = 32
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1

  # Kept to characters that survive a connection string without percent encoding.
  override_special = "-_.~"
}

# Azure Verified Module for Cosmos DB for MongoDB vCore, which wraps the
# `Microsoft.DocumentDB/mongoClusters` API. Everything this configuration adds
# on top of it is the secure by default posture: Entra ID as the only
# authentication mode, no public network access, no Data API.
module "mongo_cluster" {
  source  = "Azure/avm-res-documentdb-mongocluster/azurerm"
  version = "0.3.0"

  location  = var.location
  name      = var.cluster_name
  parent_id = azurerm_resource_group.this.id

  administrator_login          = local.native_administrator_login
  administrator_login_password = random_password.native_administrator.result

  auth_config_allowed_modes = local.allowed_auth_modes
  users                     = local.entra_users

  compute_tier    = var.compute_tier
  server_version  = var.server_version
  shard_count     = var.shard_count
  storage_size_gb = var.storage_size_gb
  storage_type    = var.storage_type
  ha_mode         = var.high_availability_mode

  # The Data API is a second, HTTPS, way into the same data. Off unless asked
  # for.
  data_api_mode = var.data_api_enabled ? "Enabled" : "Disabled"

  public_network_access = var.public_network_access_enabled ? "Enabled" : "Disabled"
  firewall_rules        = var.firewall_rules
  private_endpoints     = local.private_endpoints
  diagnostic_settings   = local.diagnostic_settings

  enable_telemetry = var.enable_telemetry
  tags             = var.tags
}
