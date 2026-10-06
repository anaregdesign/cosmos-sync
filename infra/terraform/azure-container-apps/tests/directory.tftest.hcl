mock_provider "azurerm" {}
mock_provider "azapi" {}

variables {
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
  key_vault = {
    vault_id          = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/secrets/providers/Microsoft.KeyVault/vaults/testvault"
    vault_url         = "https://testvault.vault.azure.net"
    cursor_secret_uri = "https://testvault.vault.azure.net/secrets/cursor/11111111111111111111111111111111"
  }
  existing_identity = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/host/providers/Microsoft.ManagedIdentity/userAssignedIdentities/approved-bff"
    client_id    = "66666666-6666-4666-8666-666666666666"
    principal_id = "77777777-7777-4777-8777-777777777777"
  }
  oidc = {
    issuer             = "https://11111111-1111-4111-8111-111111111111.ciamlogin.com/11111111-1111-4111-8111-111111111111/v2.0"
    audience           = "22222222-2222-4222-8222-222222222222"
    required_scope     = "Cosmos.Sync"
    allowed_client_ids = ["33333333-3333-4333-8333-333333333333"]
  }
  authorization_mode = "directory"
  directory = {
    tenant_id            = "11111111-1111-4111-8111-111111111111"
    initial_domain       = "your-customer-tenant.onmicrosoft.com"
    reader_client_id     = "55555555-5555-4555-8555-555555555555"
    workforce_tenant_ids = ["44444444-4444-4444-8444-444444444444"]
    namespace            = "cosmos-sync-v1"
    callbacks            = ["com.anaregdesign.cosmossync://auth/oauthredirect", "https://your-app.example/auth-redirect.html"]
  }
  image = "ghcr.io/anaregdesign/cosmos-sync-bff@sha256:1111111111111111111111111111111111111111111111111111111111111111"
  directory_image_verification = {
    image         = "ghcr.io/anaregdesign/cosmos-sync-bff@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    source_commit = "c9f3402d4c9d273cb963333ebc1c95845f93def0"
    verified      = true
  }
  scale = { min_replicas = 0, max_replicas = 1 }
}

run "directory_configuration_contract" {
  command = plan
  assert {
    condition = (
      local.runtime_config.authorization.mode == "directory" &&
      local.runtime_config.authorization.directory == {
        tenantId                = var.directory.tenant_id
        initialDomain           = var.directory.initial_domain
        readerClientId          = var.directory.reader_client_id
        managedIdentityClientId = var.existing_identity.client_id
        workforceTenantIds      = var.directory.workforce_tenant_ids
        namespace               = var.directory.namespace
        callbacks               = var.directory.callbacks
      } &&
      local.runtime_config.oidc.allowedClientIds == var.oidc.allowed_client_ids &&
      local.runtime_config.storage == "cosmos" && !local.runtime_config.development &&
      length(local.runtime_config.grants) == 0 && !can(local.runtime_config.grantsFile)
    )
    error_message = "The exact production directory schema must bind the selected API, sole client, callbacks and actual BFF UAMI, without a memory store or legacy grants."
  }
  assert {
    condition = (
      length(azurerm_user_assigned_identity.bff) == 0 &&
      length(one(azurerm_cosmosdb_sql_role_definition.bff.permissions).data_actions) == 6 &&
      length(local.key_vault_scopes) == 1 &&
      one(azapi_resource.app.body.properties.template.containers).command == ["/cosmos-sync-bff"] &&
      !can(one(azapi_resource.app.body.properties.template.containers).args) &&
      azapi_resource.app.body.properties.template.scale.minReplicas == 0 &&
      azapi_resource.app.body.properties.template.scale.maxReplicas == 1
    )
    error_message = "Directory selection cannot add an identity/Graph grant, broaden Cosmos/secret roles, change command behavior or increase the selected replica bounds."
  }
}

run "loopback_callback_supported" {
  command = plan
  variables { directory = merge(var.directory, { callbacks = ["http://localhost:8400/callback", "http://[::1]:8400/callback"] }) }
  assert {
    condition     = length(local.runtime_config.authorization.directory.callbacks) == 2
    error_message = "Exact registered loopback callbacks must remain supported."
  }
}

run "reject_missing_directory" {
  command = plan
  variables { directory = null }
  expect_failures = [var.directory]
}

run "reject_mixed_builtin_directory" {
  command = plan
  variables {
    authorization_mode                   = "builtin"
    builtin_authorization_image_verified = true
    directory_image_verification         = null
  }
  expect_failures = [var.directory]
}

run "reject_mixed_legacy_directory" {
  command = plan
  variables {
    authorization_mode           = "legacy"
    directory_image_verification = null
  }
  expect_failures = [var.directory]
}

run "reject_missing_image_verification" {
  command = plan
  variables { directory_image_verification = null }
  expect_failures = [azapi_resource.app]
}

run "reject_unverified_directory_image" {
  command = plan
  variables { directory_image_verification = merge(var.directory_image_verification, { verified = false }) }
  expect_failures = [var.directory_image_verification]
}

run "reject_other_verified_image" {
  command = plan
  variables { directory_image_verification = merge(var.directory_image_verification, { image = "ghcr.io/anaregdesign/cosmos-sync-bff@sha256:2222222222222222222222222222222222222222222222222222222222222222" }) }
  expect_failures = [var.directory_image_verification]
}

run "reject_unsupported_source" {
  command = plan
  variables { directory_image_verification = merge(var.directory_image_verification, { source_commit = "82e937c8659e9ec0263a78e6e3ad2f43e05be20a" }) }
  expect_failures = [var.directory_image_verification]
}

run "reject_unsupported_image" {
  command = plan
  variables {
    image = "ghcr.io/anaregdesign/cosmos-sync-bff@sha256:2651a4bca6df6f751b7f5e46d317ea9f6e4ca83081374badae142d57cdfc812a"
    directory_image_verification = merge(var.directory_image_verification, {
      image = "ghcr.io/anaregdesign/cosmos-sync-bff@sha256:2651a4bca6df6f751b7f5e46d317ea9f6e4ca83081374badae142d57cdfc812a"
    })
  }
  expect_failures = [var.directory_image_verification]
}

run "reject_short_source" {
  command = plan
  variables { directory_image_verification = merge(var.directory_image_verification, { source_commit = "c9f3402" }) }
  expect_failures = [var.directory_image_verification]
}

run "reject_bad_domain" {
  command = plan
  variables { directory = merge(var.directory, { initial_domain = "fixture.onmicrosoft.com.attacker.invalid" }) }
  expect_failures = [var.directory]
}

run "reject_empty_sources" {
  command = plan
  variables { directory = merge(var.directory, { workforce_tenant_ids = [] }) }
  expect_failures = [var.directory]
}

run "reject_duplicate_sources" {
  command = plan
  variables { directory = merge(var.directory, { workforce_tenant_ids = concat(var.directory.workforce_tenant_ids, var.directory.workforce_tenant_ids) }) }
  expect_failures = [var.directory]
}

run "reject_target_as_source" {
  command = plan
  variables { directory = merge(var.directory, { workforce_tenant_ids = [var.directory.tenant_id] }) }
  expect_failures = [var.directory]
}

run "reject_empty_namespace" {
  command = plan
  variables { directory = merge(var.directory, { namespace = "" }) }
  expect_failures = [var.directory]
}

run "reject_padded_namespace" {
  command = plan
  variables { directory = merge(var.directory, { namespace = " cosmos-sync-v1" }) }
  expect_failures = [var.directory]
}

run "reject_empty_callbacks" {
  command = plan
  variables { directory = merge(var.directory, { callbacks = [] }) }
  expect_failures = [var.directory]
}

run "reject_duplicate_callbacks" {
  command = plan
  variables { directory = merge(var.directory, { callbacks = concat(var.directory.callbacks, var.directory.callbacks) }) }
  expect_failures = [var.directory]
}

run "reject_insecure_nonloopback_callback" {
  command = plan
  variables { directory = merge(var.directory, { callbacks = ["http://app.example/callback"] }) }
  expect_failures = [var.directory]
}

run "reject_callback_userinfo" {
  command = plan
  variables { directory = merge(var.directory, { callbacks = ["https://someone@app.example/callback"] }) }
  expect_failures = [var.directory]
}

run "reject_callback_query" {
  command = plan
  variables { directory = merge(var.directory, { callbacks = ["https://app.example/callback?other=1"] }) }
  expect_failures = [var.directory]
}

run "reject_callback_invalid_escape" {
  command = plan
  variables { directory = merge(var.directory, { callbacks = ["https://app.example/callback%GG"] }) }
  expect_failures = [var.directory]
}

run "reject_callback_overlength" {
  command = plan
  variables { directory = merge(var.directory, { callbacks = ["https://app.example/${join("", [for index in range(1000) : "aaa"])}"] }) }
  expect_failures = [var.directory]
}

run "reject_wrong_issuer" {
  command = plan
  variables { oidc = merge(var.oidc, { issuer = "https://login.microsoftonline.com/11111111-1111-4111-8111-111111111111/v2.0" }) }
  expect_failures = [var.directory]
}

run "reject_wrong_tenant_claim" {
  command = plan
  variables { oidc = merge(var.oidc, { tenant_claim = "tenant" }) }
  expect_failures = [var.directory]
}

run "reject_multiple_clients" {
  command = plan
  variables { oidc = merge(var.oidc, { allowed_client_ids = ["33333333-3333-4333-8333-333333333333", "88888888-8888-4888-8888-888888888888"] }) }
  expect_failures = [var.directory]
}

run "reject_id_token_audience" {
  command = plan
  variables { oidc = merge(var.oidc, { audience = var.oidc.allowed_client_ids[0] }) }
  expect_failures = [var.directory]
}

run "reject_noncanonical_api_audience" {
  command = plan
  variables { oidc = merge(var.oidc, { audience = "api://cosmos-sync" }) }
  expect_failures = [var.directory]
}

run "reject_reader_as_managed_identity" {
  command = plan
  variables { directory = merge(var.directory, { reader_client_id = var.existing_identity.client_id }) }
  expect_failures = [azapi_resource.app]
}
