variable "subscription_id" {
  type        = string
  description = "The existing privately selected validation subscription; no new billing target."
}

variable "tenant_id" {
  type        = string
  description = "The existing validation tenant. No identity-provider registration is performed."
}

variable "resource_group_name" {
  type        = string
  description = "Existing owner-approved West US 2 validation group from private inputs. This plan does not create a group."
  validation {
    condition     = can(regex("^[a-zA-Z0-9_.()-]+$", var.resource_group_name))
    error_message = "Use the independently checked existing validation group from private inputs."
  }
}

variable "name_prefix" {
  type        = string
  description = "Exact separately approved new resource prefix from the private review proposal."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}[a-z0-9]$", var.name_prefix))
    error_message = "Use a 3-22 character lowercase prefix."
  }
}

variable "vault_name" {
  type        = string
  description = "New dedicated vault name, privately reviewed and checked for global availability."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.vault_name))
    error_message = "Use a valid dedicated vault name."
  }
}

variable "cosmos_account_id" {
  type        = string
  description = "The new successful private-only NoSQL account, independently verified from the approved manifest. Never the retained failed account."
  validation {
    condition = (
      can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft[.]DocumentDB/databaseAccounts/[a-z0-9-]+$", var.cosmos_account_id)) &&
      try(lower(split("/", var.cosmos_account_id)[2]) == lower(var.subscription_id), false) &&
      try(lower(split("/", var.cosmos_account_id)[4]) == lower(var.resource_group_name), false)
    )
    error_message = "The approved Cosmos account must be in this exact selected subscription/group."
  }
}
