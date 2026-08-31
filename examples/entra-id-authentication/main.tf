terraform {
  required_version = ">= 1.3"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "example" {
  name     = "${var.prefix}-rg"
  location = var.location
}

# The workload identity that reaches the databases. It never gets a password of
# its own, it authenticates to Azure as itself.
resource "azurerm_user_assigned_identity" "app" {
  name                = "${var.prefix}-app"
  resource_group_name = azurerm_resource_group.example.name
  location            = azurerm_resource_group.example.location
}

# A second identity that only needs to read.
resource "azurerm_user_assigned_identity" "reporting" {
  name                = "${var.prefix}-reporting"
  resource_group_name = azurerm_resource_group.example.name
  location            = azurerm_resource_group.example.location
}

module "cosmosdb" {
  source = "../.."

  name                = "${var.prefix}-mongo"
  resource_group_name = azurerm_resource_group.example.name
  location            = azurerm_resource_group.example.location

  databases = [
    { name = "orders" },
    { name = "invoices" },
  ]

  # No username or password is created for the databases at all.
  create_database_users = false

  entra_id_access = [
    {
      # Read and write, because writing needs the read-write account keys.
      principal_id         = azurerm_user_assigned_identity.app.principal_id
      role_definition_name = "DocumentDB Account Contributor"
      principal_type       = "ServicePrincipal"
    },
    {
      # Read only, this role hands out the read-only keys.
      principal_id         = azurerm_user_assigned_identity.reporting.principal_id
      role_definition_name = "Cosmos DB Account Reader Role"
      principal_type       = "ServicePrincipal"
    },
  ]

  tags = {
    example = "entra-id-authentication"
  }
}
