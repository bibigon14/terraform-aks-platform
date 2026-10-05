terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }

  # Sanitized backend - parameters supplied via -backend-config in CI/CD so
  # subscription-identifying strings are not baked into source.
  # See bootstrap.md for the storage account and container that back this.
  backend "azurerm" {}
}

provider "azurerm" {
  features {}

  # Resource providers are registered manually in bootstrap.md - don't let
  # Terraform try to re-register them on every run.
  resource_provider_registrations = "none"
}

provider "azuread" {}
