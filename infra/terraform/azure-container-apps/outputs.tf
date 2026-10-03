output "endpoint" {
  description = "Stable HTTPS BFF endpoint for the SDK/native sample; reachability depends on the environment/network."
  value       = try("https://${azapi_resource.app.output.properties.configuration.ingress.fqdn}", null)
}

output "container_app_id" {
  description = "Managed Container App ARM ID, not a live-acceptance receipt."
  value       = azapi_resource.app.id
}

output "container_app_environment_id" {
  description = "Managed ACA environment ARM ID."
  value       = azapi_resource.environment.id
}

output "identity" {
  description = "Dedicated UAMI metadata, not a credential."
  value       = local.identity
}

output "cosmos_data_scope" {
  description = "Exact existing container native role scope."
  value       = local.cosmos_scope
}

output "runtime_config" {
  description = "Nonsecret generated BFF JSON: only references, endpoints, policy and limits."
  value       = local.runtime_config
}

output "outbound_ip_addresses" {
  description = "Read-back addresses, not a stable-egress guarantee; do not automatically broaden Cosmos firewall rules."
  value       = try(azapi_resource.app.output.properties.outboundIpAddresses, [])
}
