variable "name" {
  description = "Base name for the user-assigned managed identity"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that will hold the managed identity"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL from the AKS cluster (azurerm_kubernetes_cluster.oidc_issuer_url)"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of the ServiceAccount this identity federates to"
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes ServiceAccount name this identity federates to"
  type        = string
}

variable "tags" {
  description = "Tags to apply to the managed identity"
  type        = map(string)
  default     = {}
}
