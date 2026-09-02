terraform {
  # The Azure Verified Module used here requires 1.9 or newer, and this
  # configuration relies on cross variable validation, which landed in the same
  # release.
  required_version = ">= 1.9, < 2.0"

  required_providers {
    # Pinned to 4.x because that is what the Azure Verified Module accepts.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}
