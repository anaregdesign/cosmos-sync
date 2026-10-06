variable "deployment" {
  description = "Approved Azure target. The resource group already exists; this module never creates or deletes it."
  type = object({
    subscription_id     = string
    tenant_id           = string
    resource_group_name = string
    location            = string
    name_prefix         = string
  })
  validation {
    condition = (
      can(regex("^[0-9a-fA-F-]{36}$", var.deployment.subscription_id)) &&
      can(regex("^[0-9a-fA-F-]{36}$", var.deployment.tenant_id)) &&
      can(regex("^[a-z][a-z0-9-]{1,20}[a-z0-9]$", var.deployment.name_prefix)) &&
      can(regex("^[a-zA-Z0-9_.()-]+$", var.deployment.resource_group_name)) &&
      length(var.deployment.location) > 0
    )
    error_message = "Use UUID subscription/tenant IDs, an existing resource group and a 3–22 character lowercase name prefix."
  }
}

variable "infrastructure_resource_group_name" {
  description = "Optional new, unused name for ACA's platform-managed infrastructure resource group in the environment/subnet subscription. Null preserves Azure's generated naming. This is an unqualified name, never an ARM ID or an existing application/data resource group."
  type        = string
  default     = null
  validation {
    condition = var.infrastructure_resource_group_name == null ? true : (
      can(regex("^[A-Za-z0-9_.()-]{1,90}$", var.infrastructure_resource_group_name)) &&
      !endswith(var.infrastructure_resource_group_name, ".")
    )
    error_message = "Use an unqualified 1–90 character resource group name with ASCII letters, digits, underscores, hyphens, periods or parentheses; it cannot end in a period. ARM IDs, spaces and empty names are invalid."
  }
}

variable "cosmos" {
  description = "Existing NoSQL account/database/container. No account keys are read. Operator must verify Session consistency, one write region, /scopeId partition key and no expiring TTL."
  type = object({
    account_id = string
    endpoint   = string
    database   = string
    container  = string
  })
  validation {
    condition = (
      can(regex("(?i)^/subscriptions/${var.deployment.subscription_id}/resourcegroups/[^/]+/providers/microsoft.documentdb/databaseaccounts/[a-z0-9-]+$", var.cosmos.account_id)) &&
      can(regex("^https://[a-z0-9-]+\\.documents\\.azure\\.com(:443)?/$", var.cosmos.endpoint)) &&
      can(regex("^[A-Za-z0-9_-]{1,128}$", var.cosmos.database)) &&
      can(regex("^[A-Za-z0-9_-]{1,128}$", var.cosmos.container)) &&
      lower(trimsuffix(split(".", trimprefix(var.cosmos.endpoint, "https://"))[0], ":443")) == lower(element(split("/", var.cosmos.account_id), 8))
    )
    error_message = "Reference an existing account in the selected subscription, matching public-Azure HTTPS endpoint and simple database/container names. Sovereign cloud endpoints require an explicit module adaptation."
  }
}

variable "oidc" {
  description = "Dedicated API access JWT verification. Provider registration, consent and end-user grants remain operator prerequisites."
  type = object({
    issuer             = string
    audience           = string
    required_scope     = string
    tenant_claim       = optional(string, "tid")
    token_use          = optional(string, "")
    allowed_client_ids = optional(list(string), [])
  })
  validation {
    condition = (
      can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[^?#]*)?$", var.oidc.issuer)) &&
      length(trimspace(var.oidc.audience)) > 0 &&
      can(regex("^[^[:space:]]+$", var.oidc.required_scope)) &&
      length(var.oidc.tenant_claim) > 0
    )
    error_message = "Set an HTTPS issuer, API audience, one delegated scope and tenant claim; never configure an ID-token audience."
  }
  validation {
    condition = (
      length(var.oidc.allowed_client_ids) <= 32 &&
      length(distinct(var.oidc.allowed_client_ids)) == length(var.oidc.allowed_client_ids) &&
      alltrue([for id in var.oidc.allowed_client_ids : can(regex("^[!-~]{1,256}$", id))])
    )
    error_message = "Optional allowed_client_ids must contain at most 32 distinct nonempty visible ASCII client IDs of at most 256 bytes; matching signed azp is exact."
  }
}

variable "image" {
  description = "Published BFF GHCR image, pinned to its approved multi-platform digest."
  type        = string
  validation {
    condition     = can(regex("^ghcr\\.io/[a-z0-9_.-]+/[a-z0-9_./-]+@sha256:[0-9a-f]{64}$", var.image))
    error_message = "Use ghcr.io/OWNER/IMAGE@sha256:DIGEST, not a mutable version/latest tag."
  }
}

variable "key_vault" {
  description = "Existing RBAC-enabled Key Vault and version-pinned cursor/optional metrics references. End-user authorization is separate; only secret URIs enter Terraform."
  type = object({
    vault_id           = string
    vault_url          = string
    cursor_secret_uri  = string
    metrics_secret_uri = optional(string)
  })
  validation {
    condition = (
      can(regex("(?i)^/subscriptions/${var.deployment.subscription_id}/resourcegroups/[^/]+/providers/microsoft.keyvault/vaults/[a-z0-9-]+$", var.key_vault.vault_id)) &&
      can(regex("^https://[a-z0-9-]+\\.vault\\.azure\\.net$", var.key_vault.vault_url)) &&
      lower(split(".", trimprefix(var.key_vault.vault_url, "https://"))[0]) == lower(element(split("/", var.key_vault.vault_id), 8)) &&
      (startswith(var.key_vault.cursor_secret_uri, "${var.key_vault.vault_url}/secrets/") && can(regex("^[A-Za-z0-9-]+/[0-9a-fA-F]{32}$", trimprefix(var.key_vault.cursor_secret_uri, "${var.key_vault.vault_url}/secrets/")))) &&
      (var.key_vault.metrics_secret_uri == null ? true : (startswith(var.key_vault.metrics_secret_uri, "${var.key_vault.vault_url}/secrets/") && can(regex("^[A-Za-z0-9-]+/[0-9a-fA-F]{32}$", trimprefix(var.key_vault.metrics_secret_uri, "${var.key_vault.vault_url}/secrets/")))))
    )
    error_message = "Use matching existing public-Azure Key Vault IDs/URL and versioned cursor/metrics secret URIs."
  }
}

variable "existing_identity" {
  description = "Optional existing dedicated user-assigned identity; null creates one. Values are identity metadata, never credentials."
  type = object({
    id           = string
    client_id    = string
    principal_id = string
  })
  default = null
  validation {
    condition = var.existing_identity == null ? true : (
      can(regex("(?i)^/subscriptions/${var.deployment.subscription_id}/resourcegroups/[^/]+/providers/microsoft.managedidentity/userassignedidentities/[^/]+$", var.existing_identity.id)) &&
      can(regex("^[0-9a-fA-F-]{36}$", var.existing_identity.client_id)) &&
      can(regex("^[0-9a-fA-F-]{36}$", var.existing_identity.principal_id))
    )
    error_message = "The existing UAMI must belong to the selected subscription with UUID client/principal metadata verified by the operator."
  }
}

variable "private_ghcr" {
  description = "Optional existing GitHub pull-only credential in Key Vault. Public GHCR needs no registry credentials or this input. Creating tokens is a separate owner action."
  type = object({
    username            = string
    password_secret_uri = string
  })
  default = null
  validation {
    condition = var.private_ghcr == null ? true : (
      length(var.private_ghcr.username) > 0 &&
      (startswith(var.private_ghcr.password_secret_uri, "${var.key_vault.vault_url}/secrets/") && can(regex("^[A-Za-z0-9-]+/[0-9a-fA-F]{32}$", trimprefix(var.private_ghcr.password_secret_uri, "${var.key_vault.vault_url}/secrets/"))))
    )
    error_message = "Use an existing narrowly scoped GitHub registry credential with a version-pinned URI in the same Key Vault."
  }
}

variable "network" {
  description = "Existing delegated subnet is optional for public validation and required for an internal environment. The module does not edit Cosmos/Key Vault firewalls, DNS, NAT or VNet resources."
  type = object({
    infrastructure_subnet_id = optional(string)
    internal_environment     = optional(bool, false)
    ingress_allow_cidrs      = optional(list(string), [])
  })
  default = {}
  validation {
    condition = (
      (!var.network.internal_environment || var.network.infrastructure_subnet_id != null) &&
      (var.network.infrastructure_subnet_id == null ? true : can(regex("(?i)^/subscriptions/${var.deployment.subscription_id}/resourcegroups/[^/]+/providers/microsoft.network/virtualnetworks/[^/]+/subnets/[^/]+$", var.network.infrastructure_subnet_id))) &&
      alltrue([for cidr in var.network.ingress_allow_cidrs : can(cidrnetmask(cidr))])
    )
    error_message = "An internal environment needs an approved existing delegated subnet; ingress allow rules must use valid IPv4 CIDRs."
  }
}

variable "allowed_origins" {
  description = "Exact browser HTTPS origins; an empty list is suitable for native applications. CORS is enforced by the BFF."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for origin in var.allowed_origins : can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", origin))])
    error_message = "Use exact HTTPS origins without paths, wildcards or trailing slash."
  }
}

variable "scale" {
  description = "Consumption profile only; conservative replica bounds, not a spending cap. Use min=1 for predictable startup and adjust only after live load/revocation tests."
  type = object({
    min_replicas    = optional(number, 0)
    max_replicas    = optional(number, 2)
    concurrent_http = optional(number, 16)
    cpu             = optional(number, 0.25)
    memory          = optional(string, "0.5Gi")
  })
  default = {}
  validation {
    condition = (
      var.scale.min_replicas >= 0 && var.scale.min_replicas <= var.scale.max_replicas &&
      var.scale.max_replicas >= 1 && var.scale.max_replicas <= 10 &&
      floor(var.scale.min_replicas) == var.scale.min_replicas && floor(var.scale.max_replicas) == var.scale.max_replicas &&
      var.scale.concurrent_http >= 1 && var.scale.concurrent_http <= 64 && floor(var.scale.concurrent_http) == var.scale.concurrent_http &&
      contains(["0.25:0.5Gi", "0.5:1Gi", "0.75:1.5Gi", "1:2Gi", "1.25:2.5Gi", "1.5:3Gi", "1.75:3.5Gi", "2:4Gi"], "${var.scale.cpu}:${var.scale.memory}")
    )
    error_message = "Use integer min/max replicas (max 1–10), concurrent HTTP 1–64 and a supported Consumption CPU/memory pair."
  }
}

variable "history_epoch" {
  description = "Shared cursor/history epoch. Keep identical across serving replicas; changing it forces client resync."
  type        = string
  default     = "1"
  validation {
    condition     = length(var.history_epoch) >= 1 && length(var.history_epoch) <= 128
    error_message = "Use a nonempty history epoch up to 128 characters."
  }
}

variable "authorization_mode" {
  description = "Builtin personal/shared memberships, opt-in directory lifecycle, or legacy empty grants (deny all). No mode automatically adopts another mode's ownership."
  type        = string
  default     = "builtin"
  validation {
    condition     = contains(["legacy", "builtin", "directory"], var.authorization_mode)
    error_message = "Choose builtin, explicitly configured directory, or legacy (empty/deny-all grants), never an allow-all policy."
  }
}

variable "builtin_authorization_image_verified" {
  description = "Operator assertion that the selected immutable image includes tested builtin authorization and the chosen new namespace/migration is intentional. This does not inspect the registry or authorize deployment."
  type        = bool
  default     = false
}

variable "directory" {
  description = "Server-only directory trust, required only in directory mode. Use exact lowercase UUIDs, one public client, 1–16 distinct callbacks and a 1–128 byte visible ASCII namespace. The reader's managed identity is derived from the BFF's actual assigned UAMI. No user, Graph grant or federated credential is created."
  type = object({
    tenant_id            = string
    initial_domain       = string
    reader_client_id     = string
    workforce_tenant_ids = list(string)
    namespace            = string
    callbacks            = list(string)
  })
  default = null
  validation {
    condition     = var.directory == null ? var.authorization_mode != "directory" : var.authorization_mode == "directory"
    error_message = "Directory settings are required in directory mode and forbidden in builtin/legacy modes."
  }
  validation {
    condition = var.directory == null ? true : (
      alltrue([for id in concat([var.directory.tenant_id, var.directory.reader_client_id], var.directory.workforce_tenant_ids) :
        can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", id))
      ]) &&
      can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.onmicrosoft\\.com$", var.directory.initial_domain)) &&
      length(var.directory.workforce_tenant_ids) >= 1 && length(var.directory.workforce_tenant_ids) <= 16 &&
      length(distinct(var.directory.workforce_tenant_ids)) == length(var.directory.workforce_tenant_ids) &&
      !contains(var.directory.workforce_tenant_ids, var.directory.tenant_id) &&
      can(regex("^[!-~]([ -~]{0,126}[!-~])?$", var.directory.namespace))
    )
    error_message = "Directory trust needs canonical lowercase IDs, an exact initial onmicrosoft.com domain, 1–16 distinct non-target workforce tenants and a bounded, unpadded ASCII namespace."
  }
  validation {
    condition = var.directory == null ? true : (
      var.oidc.issuer == "https://${var.directory.tenant_id}.ciamlogin.com/${var.directory.tenant_id}/v2.0" &&
      var.oidc.tenant_claim == "tid" &&
      length(var.oidc.allowed_client_ids) == 1 &&
      alltrue([for id in concat([var.oidc.audience], var.oidc.allowed_client_ids) :
        can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", id))
      ]) &&
      !contains(var.oidc.allowed_client_ids, var.oidc.audience)
    )
    error_message = "Directory mode requires the exact tenant-ID CIAM issuer, tid, a dedicated canonical API GUID audience and exactly one distinct public-client GUID."
  }
  validation {
    condition = var.directory == null ? true : (
      length(var.directory.callbacks) >= 1 && length(var.directory.callbacks) <= 16 &&
      length(distinct(var.directory.callbacks)) == length(var.directory.callbacks) &&
      alltrue([for callback in var.directory.callbacks :
        length(callback) <= 2048 && can(regex("^[!-~]+$", callback)) &&
        can(regex("^(https://[A-Za-z0-9.-]+(:[0-9]+)?|http://(localhost|127\\.0\\.0\\.1|\\[::1\\])(:[0-9]+)?|[a-z][a-z0-9+.-]*\\.[a-z0-9+.-]*://[A-Za-z0-9.-]+)(/([A-Za-z0-9._~!$&'()*+,;=:@/-]|%[0-9A-Fa-f]{2})*)?$", callback))
      ])
    )
    error_message = "Use 1–16 exact distinct bounded callbacks: HTTPS, loopback HTTP or a dotted native scheme, without userinfo, query, fragment or whitespace."
  }
}

variable "directory_image_verification" {
  description = "Reviewed directory-capable immutable image and exact source commit, plus explicit verified assertion. Metadata only, not a registry inspection, publication or deployment approval. The image must equal image; known builtin/legacy-only release artifacts are rejected."
  type = object({
    image         = string
    source_commit = string
    verified      = bool
  })
  default = null
  validation {
    condition = var.directory_image_verification == null ? true : (
      var.authorization_mode == "directory" &&
      var.directory_image_verification.image == var.image &&
      can(regex("^[0-9a-f]{40}$", var.directory_image_verification.source_commit)) &&
      var.directory_image_verification.source_commit != "0000000000000000000000000000000000000000" &&
      var.directory_image_verification.verified &&
      !contains([
        "82e937c8659e9ec0263a78e6e3ad2f43e05be20a",
        "76c1f46876b3dfd13f4bd7d4dd144cdf74efa5c0"
      ], var.directory_image_verification.source_commit) &&
      !contains([
        "sha256:a23ab75eb4518597aa26e4833787b9b77a07def717868e080944555594adc1b3",
        "sha256:2651a4bca6df6f751b7f5e46d317ea9f6e4ca83081374badae142d57cdfc812a"
      ], try(split("@", var.image)[1], ""))
    )
    error_message = "Supply verified directory-capable image/source metadata for this exact pinned image, not a different digest, mutable/unverified candidate or known builtin/legacy release."
  }
}

variable "log_destination" {
  description = "none avoids an automatic paid log workspace; azure-monitor requires separately approved diagnostic settings and an existing destination."
  type        = string
  default     = "none"
  validation {
    condition     = contains(["none", "azure-monitor"], var.log_destination)
    error_message = "Choose none or azure-monitor; this module never provisions Log Analytics."
  }
}

variable "tags" {
  description = "Ownership and cost attribution tags. Do not put personal identifiers, credentials or end-user data in tags."
  type        = map(string)
  default     = {}
}
