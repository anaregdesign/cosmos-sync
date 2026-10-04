mock_provider "azurerm" {}

override_resource {
  target          = azurerm_subnet.aca
  override_during = plan
  values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/example-validation/providers/Microsoft.Network/virtualNetworks/example-validation-vnet/subnets/aca" }
}
override_resource {
  target          = azurerm_subnet.private_endpoints
  override_during = plan
  values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/example-validation/providers/Microsoft.Network/virtualNetworks/example-validation-vnet/subnets/private-endpoints" }
}
override_resource {
  target          = azurerm_key_vault.cursor
  override_during = plan
  values          = { id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/example-validation/providers/Microsoft.KeyVault/vaults/example-validation-vault" }
}

variables {
  subscription_id     = "00000000-0000-0000-0000-000000000001"
  tenant_id           = "00000000-0000-0000-0000-000000000002"
  resource_group_name = "example-validation"
  name_prefix         = "example-validation"
  vault_name          = "example-validation-vault"
  cosmos_account_id   = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/example-validation/providers/Microsoft.DocumentDB/databaseAccounts/examplecosmos"
}

run "private_vault_without_any_public_exception" {
  command = plan
  assert {
    condition = (
      !azurerm_key_vault.cursor.public_network_access_enabled &&
      one(azurerm_key_vault.cursor.network_acls).default_action == "Deny" &&
      one(azurerm_key_vault.cursor.network_acls).bypass == "None" &&
      length(one(azurerm_key_vault.cursor.network_acls).ip_rules) == 0 &&
      length(one(azurerm_key_vault.cursor.network_acls).virtual_network_subnet_ids) == 0 &&
      azurerm_key_vault.cursor.rbac_authorization_enabled && azurerm_key_vault.cursor.purge_protection_enabled &&
      !azurerm_key_vault.cursor.enabled_for_template_deployment
    )
    error_message = "The private vault must preserve public deny, no bypass, RBAC and recovery, without template secret retrieval."
  }
}

run "separate_aca_and_private_endpoint_subnets" {
  command = plan
  assert {
    condition = (
      one(one(azurerm_subnet.aca.delegation).service_delegation).name == "Microsoft.App/environments" &&
      toset(azurerm_subnet.aca.address_prefixes) == toset(["10.227.40.0/27"]) &&
      toset(azurerm_subnet.private_endpoints.address_prefixes) == toset(["10.227.40.32/27"]) &&
      length(azurerm_subnet.private_endpoints.delegation) == 0 &&
      length(azurerm_subnet.aca.service_endpoint) == 0 &&
      length(azurerm_subnet.private_endpoints.service_endpoint) == 0 &&
      azurerm_subnet.aca.id != azurerm_subnet.private_endpoints.id
    )
    error_message = "ACA alone uses the delegated subnet; private endpoints use a separate nondelegated subnet, without incompatible service endpoints."
  }
}

run "private_links_have_exact_target_and_dns" {
  command = plan
  assert {
    condition = (
      one(azurerm_private_endpoint.cosmos.private_service_connection).private_connection_resource_id == var.cosmos_account_id &&
      toset(one(azurerm_private_endpoint.cosmos.private_service_connection).subresource_names) == toset(["Sql"]) &&
      one(azurerm_private_endpoint.vault.private_service_connection).private_connection_resource_id == azurerm_key_vault.cursor.id &&
      toset(one(azurerm_private_endpoint.vault.private_service_connection).subresource_names) == toset(["vault"]) &&
      azurerm_private_endpoint.cosmos.subnet_id == azurerm_subnet.private_endpoints.id &&
      azurerm_private_endpoint.vault.subnet_id == azurerm_subnet.private_endpoints.id &&
      azurerm_private_dns_zone.cosmos.name == "privatelink.documents.azure.com" &&
      azurerm_private_dns_zone.vault.name == "privatelink.vaultcore.azure.net" &&
      !azurerm_private_dns_zone_virtual_network_link.cosmos.registration_enabled &&
      !azurerm_private_dns_zone_virtual_network_link.vault.registration_enabled
    )
    error_message = "Both private links must bind only approved services/subresources in the selected endpoint subnet, with matching private DNS and no automatic registration."
  }
}

run "reject_unrelated_cosmos_account" {
  command = plan
  variables { cosmos_account_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/unrelated/providers/Microsoft.DocumentDB/databaseAccounts/otheraccount" }
  expect_failures = [var.cosmos_account_id]
}

run "reject_invalid_resource_group" {
  command = plan
  variables { resource_group_name = "invalid/group" }
  expect_failures = [var.resource_group_name]
}

run "reject_rg_regex_metacharacter_alias" {
  command = plan
  variables {
    resource_group_name = "example.validation"
    cosmos_account_id   = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/exampleXvalidation/providers/Microsoft.DocumentDB/databaseAccounts/examplecosmos"
  }
  expect_failures = [var.cosmos_account_id]
}

run "reject_provider_namespace_lookalike" {
  command = plan
  variables { cosmos_account_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/example-validation/providers/MicrosoftXDocumentDB/databaseAccounts/examplecosmos" }
  expect_failures = [var.cosmos_account_id]
}
