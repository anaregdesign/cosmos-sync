output "subnet_id" { value = azurerm_subnet.aca.id }
output "private_endpoint_subnet_id" { value = azurerm_subnet.private_endpoints.id }
output "vault_id" { value = azurerm_key_vault.cursor.id }
output "vault_url" { value = trimsuffix(azurerm_key_vault.cursor.vault_uri, "/") }
output "cursor_secret_scope" { value = local.cursor_scope }
output "status" { value = "Prepared reference only; a mock plan is not deployment approval or live acceptance." }
