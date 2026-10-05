variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "westus3"
}

variable "project_name" {
  description = "Short name used in resource naming"
  type        = string
  default     = "aks-platform"
}

variable "environment" {
  description = "Environment tag (prod/dev/demo)"
  type        = string
  default     = "demo"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version (minor only; AKS picks the current patch)"
  type        = string
  default     = "1.35"
}

variable "node_count" {
  description = "Initial node count in the system node pool"
  type        = number
  default     = 2
}

variable "node_vm_size" {
  description = "VM size for AKS nodes"
  type        = string
  default     = "Standard_D2s_v4"
}

variable "admin_group_object_ids" {
  description = "Object IDs of Entra ID groups to grant AKS cluster admin"
  type        = list(string)
  default     = []
}
