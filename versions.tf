terraform {
  # 1.11 is the floor of the Key Vault module, the other Azure Verified Modules
  # used here ask for 1.9.
  required_version = ">= 1.11"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # The Azure Verified Modules used here have not moved to azurerm 5 yet:
      # the Cosmos DB module pins `~> 4.0` and the managed identity module
      # pins `< 5.0.0`, so the whole configuration stays on azurerm 4.
      version = ">= 4.81, < 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
