locals {
  resource_group_id = "/subscriptions/${var.deployment.subscription_id}/resourceGroups/${var.deployment.resource_group_name}"
  cosmos_segments   = split("/", var.cosmos.account_id)
  cosmos_scope      = "${var.cosmos.account_id}/dbs/${var.cosmos.database}/colls/${var.cosmos.container}"
  tags              = merge({ managed_by = "cosmos-sync", retention = "retain-for-reuse" }, var.tags)
  identity = var.existing_identity == null ? {
    id           = azurerm_user_assigned_identity.bff[0].id
    client_id    = azurerm_user_assigned_identity.bff[0].client_id
    principal_id = azurerm_user_assigned_identity.bff[0].principal_id
  } : var.existing_identity

  secret_uris = merge(
    { cursor = var.key_vault.cursor_secret_uri },
    var.key_vault.metrics_secret_uri == null ? {} : { metrics = var.key_vault.metrics_secret_uri },
    var.private_ghcr == null ? {} : { registry = var.private_ghcr.password_secret_uri }
  )
  secret_names     = { for name, uri in local.secret_uris : name => split("/", uri)[4] }
  key_vault_scopes = toset([for name in values(local.secret_names) : "${var.key_vault.vault_id}/secrets/${name}"])
  runtime_config = {
    listen         = ":8080"
    development    = false
    storage        = "cosmos"
    historyEpoch   = var.history_epoch
    allowedOrigins = var.allowed_origins
    oidc = merge({
      issuer        = var.oidc.issuer
      audience      = var.oidc.audience
      requiredScope = var.oidc.required_scope
      tenantClaim   = var.oidc.tenant_claim
      tokenUse      = var.oidc.token_use
    }, length(var.oidc.allowed_client_ids) == 0 ? {} : { allowedClientIds = var.oidc.allowed_client_ids })
    cosmos = {
      endpoint          = var.cosmos.endpoint
      database          = var.cosmos.database
      container         = var.cosmos.container
      singleWriteRegion = true
    }
    authorization = merge({ mode = var.authorization_mode }, var.directory == null ? {} : {
      directory = {
        tenantId                = var.directory.tenant_id
        initialDomain           = var.directory.initial_domain
        readerClientId          = var.directory.reader_client_id
        managedIdentityClientId = local.identity.client_id
        workforceTenantIds      = var.directory.workforce_tenant_ids
        namespace               = var.directory.namespace
        callbacks               = var.directory.callbacks
      }
    })
    grants    = []
    events    = { enabled = true, pollMilliseconds = 5000, heartbeatMilliseconds = 10000, maxStreamSeconds = 20 }
    snapshots = { enabled = true, maxChanges = 4096, maxReplayBytes = 67108864 }
    limits = {
      enabled           = true, maxConcurrentRequests = 64, maxConcurrentStreams = 8,
      requestsPerMinute = 120, burst = 30, maxPrincipalBuckets = 10000,
      maxDocumentBytes  = 262144, maxSyncPageBytes = 4194304
    }
    retention = { maxJournalEvents = 10000, maxEstimatedRetainedBytes = 134217728 }
  }
  probes = [
    { type = "Liveness", httpGet = { path = "/healthz", port = 8080, scheme = "HTTP" }, initialDelaySeconds = 1, periodSeconds = 15, timeoutSeconds = 3, failureThreshold = 3, successThreshold = 1 },
    { type = "Readiness", httpGet = { path = "/readyz", port = 8080, scheme = "HTTP" }, initialDelaySeconds = 1, periodSeconds = 10, timeoutSeconds = 3, failureThreshold = 3, successThreshold = 1 },
    { type = "Startup", httpGet = { path = "/readyz", port = 8080, scheme = "HTTP" }, initialDelaySeconds = 1, periodSeconds = 5, timeoutSeconds = 3, failureThreshold = 24, successThreshold = 1 }
  ]
}

resource "azurerm_user_assigned_identity" "bff" {
  count               = var.existing_identity == null ? 1 : 0
  name                = "${var.deployment.name_prefix}-bff"
  location            = var.deployment.location
  resource_group_name = var.deployment.resource_group_name
  tags                = local.tags
  lifecycle { prevent_destroy = true }
}

resource "azurerm_cosmosdb_sql_role_definition" "bff" {
  name                = "${var.deployment.name_prefix}-bff-container"
  account_name        = local.cosmos_segments[8]
  resource_group_name = local.cosmos_segments[4]
  role_definition_id  = uuidv5("url", "${var.cosmos.account_id}/${var.deployment.name_prefix}/cosmos-role")
  assignable_scopes   = [local.cosmos_scope]
  type                = "CustomRole"
  permissions {
    data_actions = [
      "Microsoft.DocumentDB/databaseAccounts/readMetadata",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/readChangeFeed"
    ]
  }
  lifecycle { prevent_destroy = true }
}

resource "azurerm_cosmosdb_sql_role_assignment" "bff" {
  name                = uuidv5("url", "${local.cosmos_scope}/${var.deployment.name_prefix}/cosmos-assignment")
  account_name        = local.cosmos_segments[8]
  resource_group_name = local.cosmos_segments[4]
  role_definition_id  = azurerm_cosmosdb_sql_role_definition.bff.id
  principal_id        = local.identity.principal_id
  scope               = local.cosmos_scope
  lifecycle { prevent_destroy = true }
}

resource "azurerm_role_assignment" "key_vault_secret" {
  for_each                         = local.key_vault_scopes
  name                             = uuidv5("url", "${each.value}/${var.deployment.name_prefix}/secret-reader")
  scope                            = each.value
  role_definition_id               = "/subscriptions/${var.deployment.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"
  principal_id                     = local.identity.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  lifecycle { prevent_destroy = true }
}

# AzAPI GET does not call listSecrets; only approved secret URI references enter
# the body/state. AzureRM's Container App resource reads listSecrets into state.
resource "azapi_resource" "environment" {
  type      = "Microsoft.App/managedEnvironments@2025-07-01"
  name      = "${var.deployment.name_prefix}-environment"
  parent_id = local.resource_group_id
  location  = var.deployment.location
  tags      = local.tags
  body = {
    properties = merge({
      # Azure CLI maps its "none" option to JSON null; the RP rejects "none".
      # No Log Analytics workspace configuration is created in either mode.
      appLogsConfiguration = {
        destination               = var.log_destination == "none" ? null : var.log_destination
        logAnalyticsConfiguration = null
      }
      peerTrafficConfiguration = { encryption = { enabled = true } }
      publicNetworkAccess      = var.network.internal_environment ? "Disabled" : "Enabled"
      zoneRedundant            = false
      workloadProfiles         = [{ name = "Consumption", workloadProfileType = "Consumption" }]
      }, var.network.infrastructure_subnet_id == null ? {} : {
      vnetConfiguration = {
        infrastructureSubnetId = var.network.infrastructure_subnet_id
        internal               = var.network.internal_environment
      }
      }, var.infrastructure_resource_group_name == null ? {} : {
      infrastructureResourceGroup = var.infrastructure_resource_group_name
    })
  }
  response_export_values = ["properties.defaultDomain", "properties.staticIp", "properties.peerTrafficConfiguration"]
  lifecycle { prevent_destroy = true }
}

resource "azapi_resource" "app" {
  type      = "Microsoft.App/containerApps@2025-07-01"
  name      = "${var.deployment.name_prefix}-bff"
  parent_id = local.resource_group_id
  location  = var.deployment.location
  tags      = local.tags
  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity.id]
  }
  body = {
    properties = {
      managedEnvironmentId = azapi_resource.environment.id
      workloadProfileName  = "Consumption"
      configuration = {
        activeRevisionsMode  = "Single"
        maxInactiveRevisions = 1
        ingress = {
          external              = true
          allowInsecure         = false
          targetPort            = 8080
          transport             = "Http"
          clientCertificateMode = "Ignore"
          traffic               = [{ latestRevision = true, weight = 100 }]
          ipSecurityRestrictions = [for i, cidr in var.network.ingress_allow_cidrs : {
            name = "allowed-${i}", ipAddressRange = cidr, action = "Allow", description = "Explicit operator-approved ingress network"
          }]
        }
        secrets    = [for name, uri in local.secret_uris : { name = name, keyVaultUrl = uri, identity = local.identity.id }]
        registries = var.private_ghcr == null ? [] : [{ server = "ghcr.io", username = var.private_ghcr.username, passwordSecretRef = "registry" }]
      }
      template = {
        terminationGracePeriodSeconds = 15
        containers = [{
          name  = "bff"
          image = var.image
          # Use env JSON alone; the image defaults to a file-config CMD.
          command   = ["/cosmos-sync-bff"]
          resources = { cpu = var.scale.cpu, memory = var.scale.memory }
          env = concat([
            { name = "COSMOS_SYNC_CONFIG_JSON", value = jsonencode(local.runtime_config) },
            { name = "COSMOS_SYNC_TLS_MODE", value = "container-apps" },
            { name = "AZURE_TOKEN_CREDENTIALS", value = "ManagedIdentityCredential" },
            { name = "AZURE_CLIENT_ID", value = local.identity.client_id },
            { name = "COSMOS_SYNC_CURSOR_KEY_BASE64", secretRef = "cursor" }
          ], var.key_vault.metrics_secret_uri == null ? [] : [{ name = "COSMOS_SYNC_METRICS_TOKEN", secretRef = "metrics" }])
          probes = local.probes
        }]
        scale = {
          minReplicas     = var.scale.min_replicas
          maxReplicas     = var.scale.max_replicas
          cooldownPeriod  = 300
          pollingInterval = 30
          rules           = [{ name = "http", http = { metadata = { concurrentRequests = tostring(var.scale.concurrent_http) } } }]
        }
      }
    }
  }
  response_export_values = ["properties.configuration.ingress.fqdn", "properties.latestRevisionName", "properties.outboundIpAddresses"]
  depends_on             = [azurerm_cosmosdb_sql_role_assignment.bff, azurerm_role_assignment.key_vault_secret]
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.authorization_mode != "builtin" || var.builtin_authorization_image_verified
      error_message = "Builtin requires a verified compatible image and intentional new-namespace choice. Review release evidence then set builtin_authorization_image_verified=true; this flag is not cloud-deployment permission."
    }
    precondition {
      condition     = var.authorization_mode != "directory" || var.directory_image_verification != null
      error_message = "Directory requires reviewed compatible immutable image/source metadata; configuration support is not publication or deployment permission."
    }
    precondition {
      condition = var.directory == null ? true : (
        can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", local.identity.client_id)) &&
        var.directory.reader_client_id != local.identity.client_id
      )
      error_message = "Directory mode requires the assigned UAMI's canonical lowercase client ID, distinct from the cross-tenant reader application."
    }
  }
}
