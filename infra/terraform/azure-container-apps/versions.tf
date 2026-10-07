terraform {
  required_version = ">= 1.11.0, < 1.16.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.8.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "= 2.13.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                 = var.deployment.subscription_id
  tenant_id                       = var.deployment.tenant_id
  resource_provider_registrations = "none"
}

provider "azapi" {
  subscription_id             = var.deployment.subscription_id
  tenant_id                   = var.deployment.tenant_id
  enable_preflight            = false
  skip_provider_registration  = true
  preserve_resource_id_casing = true
}
