# Mock plan tests use no Azure credentials and perform no provider/cloud API calls.
mock_provider "azurerm" {
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/host/providers/Microsoft.ManagedIdentity/userAssignedIdentities/test-bff"
      client_id    = "00000000-0000-0000-0000-000000000010"
      principal_id = "00000000-0000-0000-0000-000000000011"
    }
  }
}

mock_provider "azapi" {}

variables {
  builtin_authorization_image_verified = true
  deployment = {
    subscription_id     = "00000000-0000-0000-0000-000000000001"
    tenant_id           = "00000000-0000-0000-0000-000000000002"
    resource_group_name = "host"
    location            = "westus2"
    name_prefix         = "test-sync"
  }
  cosmos = {
    account_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/data/providers/Microsoft.DocumentDB/databaseAccounts/testcosmos"
    endpoint   = "https://testcosmos.documents.azure.com:443/"
    database   = "sync"
    container  = "documents"
  }
  oidc  = { issuer = "https://login.example.test/", audience = "sync-api", required_scope = "Cosmos.Sync" }
  image = "ghcr.io/anaregdesign/cosmos-sync-bff@sha256:1111111111111111111111111111111111111111111111111111111111111111"
  key_vault = {
    vault_id          = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/secrets/providers/Microsoft.KeyVault/vaults/testvault"
    vault_url         = "https://testvault.vault.azure.net"
    cursor_secret_uri = "https://testvault.vault.azure.net/secrets/cursor/11111111111111111111111111111111"
  }
}

run "standard_security_boundary" {
  command = plan
  assert {
    condition = (
      azapi_resource.environment.body.properties.peerTrafficConfiguration.encryption.enabled &&
      jsondecode(jsonencode(azapi_resource.environment.body)).properties.appLogsConfiguration.destination == null &&
      jsondecode(jsonencode(azapi_resource.environment.body)).properties.appLogsConfiguration.logAnalyticsConfiguration == null &&
      !can(azapi_resource.environment.body.properties.infrastructureResourceGroup) &&
      azapi_resource.app.body.properties.configuration.ingress.allowInsecure == false &&
      azapi_resource.app.body.properties.configuration.activeRevisionsMode == "Single"
    )
    error_message = "Default deployment must encrypt platform traffic, require HTTPS ingress and avoid an automatic paid logging destination."
  }
  assert {
    condition = (
      azurerm_cosmosdb_sql_role_assignment.bff.scope == "${var.cosmos.account_id}/dbs/sync/colls/documents" &&
      length(one(azurerm_cosmosdb_sql_role_definition.bff.permissions).data_actions) == 6 &&
      !contains(one(azurerm_cosmosdb_sql_role_definition.bff.permissions).data_actions, "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/delete") &&
      alltrue([for scope in local.key_vault_scopes : startswith(scope, "${var.key_vault.vault_id}/secrets/")])
    )
    error_message = "Data access must remain container-scoped with no hard-delete/wildcard permissions, and vault access must stop at named secrets."
  }
  assert {
    condition = (
      local.runtime_config.development == false && local.runtime_config.storage == "cosmos" &&
      !can(local.runtime_config.oidc.allowedClientIds) &&
      local.runtime_config.authorization.mode == "builtin" && length(local.runtime_config.grants) == 0 &&
      length(azapi_resource.app.body.properties.configuration.secrets) == 1 &&
      alltrue([for secret in azapi_resource.app.body.properties.configuration.secrets : !can(secret.value)]) &&
      length(azapi_resource.app.body.properties.configuration.registries) == 0 &&
      local.runtime_config.events.maxStreamSeconds < 30
    )
    error_message = "Use fail-closed authorization and shared key references, no raw Terraform secrets/private pulls by default, and bound SSE below BFF write timeout."
  }
}

run "explicit_authorized_clients_render_exactly" {
  command = plan
  variables {
    oidc = {
      issuer             = "https://login.example.test/"
      audience           = "sync-api"
      required_scope     = "Cosmos.Sync"
      allowed_client_ids = ["abcdef01-0000-0000-0000-000000000001", "abcdef01-0000-0000-0000-000000000002"]
    }
  }
  assert {
    condition = (
      local.runtime_config.oidc.allowedClientIds == var.oidc.allowed_client_ids &&
      local.runtime_config.oidc.issuer == var.oidc.issuer &&
      local.runtime_config.oidc.audience == var.oidc.audience &&
      local.runtime_config.oidc.requiredScope == var.oidc.required_scope
    )
    error_message = "Explicit client IDs must render exactly as an additional signed-azp admission requirement, preserving issuer/audience/scope."
  }
}

run "empty_authorized_clients_preserve_old_image_configuration" {
  command = plan
  variables { oidc = { issuer = "https://login.example.test/", audience = "sync-api", required_scope = "Cosmos.Sync", allowed_client_ids = [] } }
  assert {
    condition     = !can(local.runtime_config.oidc.allowedClientIds)
    error_message = "An empty client list must omit the new JSON key for already published strict-decoder images."
  }
}

run "reject_empty_authorized_client_identifier" {
  command = plan
  variables { oidc = { issuer = "https://login.example.test/", audience = "sync-api", required_scope = "Cosmos.Sync", allowed_client_ids = [""] } }
  expect_failures = [var.oidc]
}

run "reject_duplicate_authorized_clients" {
  command = plan
  variables { oidc = { issuer = "https://login.example.test/", audience = "sync-api", required_scope = "Cosmos.Sync", allowed_client_ids = ["client-one", "client-one"] } }
  expect_failures = [var.oidc]
}

run "reject_authorized_client_whitespace" {
  command = plan
  variables { oidc = { issuer = "https://login.example.test/", audience = "sync-api", required_scope = "Cosmos.Sync", allowed_client_ids = ["client one"] } }
  expect_failures = [var.oidc]
}

run "reject_authorized_client_non_ascii" {
  command = plan
  variables { oidc = { issuer = "https://login.example.test/", audience = "sync-api", required_scope = "Cosmos.Sync", allowed_client_ids = ["client-\u00e9"] } }
  expect_failures = [var.oidc]
}

run "reject_authorized_client_overlength" {
  command = plan
  variables { oidc = { issuer = "https://login.example.test/", audience = "sync-api", required_scope = "Cosmos.Sync", allowed_client_ids = [join("", [for index in range(257) : "a"])] } }
  expect_failures = [var.oidc]
}

run "reject_too_many_authorized_clients" {
  command = plan
  variables { oidc = { issuer = "https://login.example.test/", audience = "sync-api", required_scope = "Cosmos.Sync", allowed_client_ids = [for index in range(33) : "client-${index}"] } }
  expect_failures = [var.oidc]
}

run "azure_monitor_keeps_explicit_destination_without_workspace" {
  command = plan
  variables { log_destination = "azure-monitor" }
  assert {
    condition = (
      jsondecode(jsonencode(azapi_resource.environment.body)).properties.appLogsConfiguration.destination == "azure-monitor" &&
      jsondecode(jsonencode(azapi_resource.environment.body)).properties.appLogsConfiguration.logAnalyticsConfiguration == null
    )
    error_message = "Azure Monitor must retain its explicit wire destination without a Log Analytics workspace or shared key; disabled logging renders JSON null."
  }
}

run "named_platform_infrastructure_group" {
  command = plan
  variables {
    infrastructure_resource_group_name = "ME_sync-validation_1(aca)"
    network = {
      infrastructure_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/approved/subnets/apps"
    }
  }
  assert {
    condition = (
      azapi_resource.environment.body.properties.infrastructureResourceGroup == "ME_sync-validation_1(aca)" &&
      azapi_resource.environment.parent_id == "/subscriptions/${var.deployment.subscription_id}/resourceGroups/${var.deployment.resource_group_name}" &&
      azapi_resource.environment.body.properties.vnetConfiguration.infrastructureSubnetId == var.network.infrastructure_subnet_id
    )
    error_message = "The supplied unqualified infrastructure group name must render exactly without changing the selected environment/subnet subscription."
  }
}

run "reject_platform_infrastructure_group_arm_id" {
  command = plan
  variables {
    infrastructure_resource_group_name = "/subscriptions/00000000-0000-0000-0000-000000000099/resourceGroups/other"
  }
  expect_failures = [var.infrastructure_resource_group_name]
}

run "reject_platform_infrastructure_group_trailing_period" {
  command = plan
  variables { infrastructure_resource_group_name = "invalid." }
  expect_failures = [var.infrastructure_resource_group_name]
}

run "reject_platform_infrastructure_group_empty_name" {
  command = plan
  variables { infrastructure_resource_group_name = "" }
  expect_failures = [var.infrastructure_resource_group_name]
}

run "reject_platform_infrastructure_group_whitespace" {
  command = plan
  variables { infrastructure_resource_group_name = "invalid group" }
  expect_failures = [var.infrastructure_resource_group_name]
}

run "reject_platform_infrastructure_group_overlength" {
  command = plan
  variables { infrastructure_resource_group_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  expect_failures = [var.infrastructure_resource_group_name]
}

run "explicit_legacy_deny_all" {
  command = plan
  variables { authorization_mode = "legacy" }
  assert {
    condition = (
      local.runtime_config.authorization.mode == "legacy" && length(local.runtime_config.grants) == 0 &&
      !can(local.runtime_config.grantsFile) && !can(local.runtime_config.grantsKeyVault)
    )
    error_message = "Legacy must preserve empty/deny-all policy and cannot introduce external secret grants."
  }
}

run "reject_unverified_builtin_image" {
  command = plan
  variables { builtin_authorization_image_verified = false }
  expect_failures = [azapi_resource.app]
}

run "reject_lookalike_secret_host" {
  command = plan
  variables {
    key_vault = {
      vault_id          = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/secrets/providers/Microsoft.KeyVault/vaults/testvault"
      vault_url         = "https://testvault.vault.azure.net"
      cursor_secret_uri = "https://testvault-vault-azure-net/secrets/cursor/11111111111111111111111111111111"
    }
  }
  expect_failures = [var.key_vault]
}

run "reject_lookalike_private_registry_secret_host" {
  command = plan
  variables {
    private_ghcr = { username = "example", password_secret_uri = "https://testvault-vault-azure-net/secrets/registry/11111111111111111111111111111111" }
  }
  expect_failures = [var.private_ghcr]
}

run "reject_lookalike_metrics_secret_host" {
  command = plan
  variables {
    key_vault = {
      vault_id           = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/secrets/providers/Microsoft.KeyVault/vaults/testvault"
      vault_url          = "https://testvault.vault.azure.net"
      cursor_secret_uri  = "https://testvault.vault.azure.net/secrets/cursor/11111111111111111111111111111111"
      metrics_secret_uri = "https://testvault-vault-azure-net/secrets/metrics/22222222222222222222222222222222"
    }
  }
  expect_failures = [var.key_vault]
}

run "reject_unknown_authorization_mode" {
  command = plan
  variables { authorization_mode = "allow-all" }
  expect_failures = [var.authorization_mode]
}

run "existing_identity_private_pull_internal_network" {
  command = plan
  variables {
    existing_identity = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/host/providers/Microsoft.ManagedIdentity/userAssignedIdentities/approved-bff"
      client_id    = "00000000-0000-0000-0000-000000000010"
      principal_id = "00000000-0000-0000-0000-000000000011"
    }
    private_ghcr = { username = "example-pull-only", password_secret_uri = "https://testvault.vault.azure.net/secrets/registry/22222222222222222222222222222222" }
    network = {
      infrastructure_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/approved/subnets/apps"
      internal_environment     = true
      ingress_allow_cidrs      = ["192.0.2.0/24"]
    }
    scale = { min_replicas = 1, max_replicas = 2 }
  }
  assert {
    condition = (
      length(azurerm_user_assigned_identity.bff) == 0 &&
      azapi_resource.environment.body.properties.publicNetworkAccess == "Disabled" &&
      azapi_resource.environment.body.properties.vnetConfiguration.internal &&
      azapi_resource.app.body.properties.configuration.ingress.external &&
      azapi_resource.app.body.properties.configuration.registries[0].passwordSecretRef == "registry" &&
      length(local.key_vault_scopes) == 2
    )
    error_message = "Existing UAMI and internal environment must retain their boundary; private registry credentials must be referenced from one named vault secret."
  }
}

run "reject_mutable_image" {
  command = plan
  variables { image = "ghcr.io/anaregdesign/cosmos-sync-bff:latest" }
  expect_failures = [var.image]
}

run "reject_unversioned_cursor_key" {
  command = plan
  variables {
    key_vault = {
      vault_id          = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/secrets/providers/Microsoft.KeyVault/vaults/testvault"
      vault_url         = "https://testvault.vault.azure.net"
      cursor_secret_uri = "https://testvault.vault.azure.net/secrets/cursor"
    }
  }
  expect_failures = [var.key_vault]
}

run "reject_cosmos_identity_mismatch" {
  command = plan
  variables {
    cosmos = {
      account_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/data/providers/Microsoft.DocumentDB/databaseAccounts/testcosmos"
      endpoint   = "https://different-account.documents.azure.com:443/"
      database   = "sync"
      container  = "documents"
    }
  }
  expect_failures = [var.cosmos]
}

run "reject_internal_without_subnet" {
  command = plan
  variables { network = { internal_environment = true } }
  expect_failures = [var.network]
}

run "reject_unbounded_scale" {
  command = plan
  variables { scale = { max_replicas = 100 } }
  expect_failures = [var.scale]
}

run "reject_wildcard_origin" {
  command = plan
  variables { allowed_origins = ["https://*.example.test"] }
  expect_failures = [var.allowed_origins]
}

run "reject_plaintext_issuer" {
  command = plan
  variables { oidc = { issuer = "http://issuer.example.test/", audience = "sync-api", required_scope = "Cosmos.Sync" } }
  expect_failures = [var.oidc]
}
