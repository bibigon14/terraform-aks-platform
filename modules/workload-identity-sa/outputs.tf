output "client_id" {
  description = "Managed Identity client_id - put on the Kubernetes ServiceAccount under annotation azure.workload.identity/client-id"
  value       = azurerm_user_assigned_identity.this.client_id
}

output "principal_id" {
  description = "Managed Identity principal_id - use for Azure role assignments"
  value       = azurerm_user_assigned_identity.this.principal_id
}

output "identity_id" {
  description = "Full ARM resource ID of the Managed Identity"
  value       = azurerm_user_assigned_identity.this.id
}

output "service_account_annotation" {
  description = "Annotation map to apply to the Kubernetes ServiceAccount"
  value = {
    "azure.workload.identity/client-id" = azurerm_user_assigned_identity.this.client_id
  }
}
