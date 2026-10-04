# Local preparation only. No approval or live ARM acceptance is implied.
locals {
  location          = "westus2"
  name_prefix       = var.name_prefix
  resource_group_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"
  vault_name        = var.vault_name
  vault_id          = "${local.resource_group_id}/providers/Microsoft.KeyVault/vaults/${local.vault_name}"
  cursor_scope      = "${local.vault_id}/secrets/cosmos-sync-cursor"
  tags              = { managed_by = "cosmos-sync", purpose = "validation", retention = "retain-for-reuse" }
}

resource "azurerm_virtual_network" "validation" {
  name                = "${local.name_prefix}-vnet"
  location            = local.location
  resource_group_name = var.resource_group_name
  address_space       = ["10.227.40.0/24"]
  tags                = local.tags
  lifecycle { prevent_destroy = true }
}

resource "azurerm_subnet" "aca" {
  name                 = "aca"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.validation.name
  address_prefixes     = ["10.227.40.0/27"]
  delegation {
    name = "aca"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
  # Service endpoints cannot reach the policy-enforced private-only account.
  lifecycle { prevent_destroy = true }
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "private-endpoints"
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.validation.name
  address_prefixes                  = ["10.227.40.32/27"]
  private_endpoint_network_policies = "Disabled"
  lifecycle { prevent_destroy = true }
}

resource "azurerm_key_vault" "cursor" {
  name                            = local.vault_name
  location                        = local.location
  resource_group_name             = var.resource_group_name
  tenant_id                       = var.tenant_id
  sku_name                        = "standard"
  rbac_authorization_enabled      = true
  purge_protection_enabled        = true
  soft_delete_retention_days      = 90
  public_network_access_enabled   = false
  enabled_for_deployment          = false
  enabled_for_disk_encryption     = false
  enabled_for_template_deployment = false
  network_acls {
    bypass                     = "None"
    default_action             = "Deny"
    ip_rules                   = []
    virtual_network_subnet_ids = []
  }
  tags = local.tags
  lifecycle { prevent_destroy = true }
}

resource "azurerm_private_dns_zone" "cosmos" {
  name                = "privatelink.documents.azure.com"
  resource_group_name = var.resource_group_name
  tags                = local.tags
  lifecycle { prevent_destroy = true }
}
resource "azurerm_private_dns_zone" "vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.resource_group_name
  tags                = local.tags
  lifecycle { prevent_destroy = true }
}

resource "azurerm_private_dns_zone_virtual_network_link" "cosmos" {
  name                 = "${local.name_prefix}-cosmos-link"
  private_dns_zone_id  = azurerm_private_dns_zone.cosmos.id
  virtual_network_id   = azurerm_virtual_network.validation.id
  registration_enabled = false
  tags                 = local.tags
  lifecycle { prevent_destroy = true }
}
resource "azurerm_private_dns_zone_virtual_network_link" "vault" {
  name                 = "${local.name_prefix}-vault-link"
  private_dns_zone_id  = azurerm_private_dns_zone.vault.id
  virtual_network_id   = azurerm_virtual_network.validation.id
  registration_enabled = false
  tags                 = local.tags
  lifecycle { prevent_destroy = true }
}

resource "azurerm_private_endpoint" "cosmos" {
  name                          = "${local.name_prefix}-cosmos-pe"
  custom_network_interface_name = "${local.name_prefix}-cosmos-pe-nic"
  location                      = local.location
  resource_group_name           = var.resource_group_name
  subnet_id                     = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name                           = "cosmos"
    private_connection_resource_id = var.cosmos_account_id
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "cosmos"
    private_dns_zone_ids = [azurerm_private_dns_zone.cosmos.id]
  }
  tags = local.tags
  lifecycle { prevent_destroy = true }
}

resource "azurerm_private_endpoint" "vault" {
  name                          = "${local.name_prefix}-vault-pe"
  custom_network_interface_name = "${local.name_prefix}-vault-pe-nic"
  location                      = local.location
  resource_group_name           = var.resource_group_name
  subnet_id                     = azurerm_subnet.private_endpoints.id
  private_service_connection {
    name                           = "vault"
    private_connection_resource_id = azurerm_key_vault.cursor.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "vault"
    private_dns_zone_ids = [azurerm_private_dns_zone.vault.id]
  }
  tags = local.tags
  lifecycle { prevent_destroy = true }
}
