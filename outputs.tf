output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.main.name
}

output "resource_group_name" {
  description = "Resource group holding the AKS cluster"
  value       = azurerm_resource_group.main.name
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL - needed when wiring Workload Identity federated credentials from outside Terraform"
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "kubeconfig_command" {
  description = "Command to merge AKS credentials into local kubeconfig"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name} --overwrite-existing"
}

output "workload_identity_demo_client_id" {
  description = "client_id to put on the Kubernetes ServiceAccount annotation 'azure.workload.identity/client-id'"
  value       = module.workload_identity_demo.client_id
}
