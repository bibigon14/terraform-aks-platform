data "azurerm_client_config" "current" {}

locals {
  common_tags = {
    project     = var.project_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${var.project_name}-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "aks-${var.project_name}-${var.environment}"
  kubernetes_version  = var.kubernetes_version

  # Required to use Azure AD Workload Identity Federation inside the cluster.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name                 = "system"
    node_count           = var.node_count
    vm_size              = var.node_vm_size
    orchestrator_version = var.kubernetes_version

    upgrade_settings {
      max_surge = "10%"
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = "10.244.0.0/16"
    load_balancer_sku   = "standard"
  }

  azure_active_directory_role_based_access_control {
    tenant_id              = data.azurerm_client_config.current.tenant_id
    admin_group_object_ids = var.admin_group_object_ids
    azure_rbac_enabled     = true
  }

  tags = local.common_tags
}

# Example Workload Identity consumer - creates a managed identity federated to
# a Kubernetes ServiceAccount at `default/demo-workload`. The cluster-side
# ServiceAccount referencing this identity is NOT provisioned here (that
# belongs in a GitOps repo); the module gives you the annotation value to
# attach to it.
module "workload_identity_demo" {
  source = "./modules/workload-identity-sa"

  name                 = "wi-${var.project_name}-demo"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  oidc_issuer_url      = azurerm_kubernetes_cluster.main.oidc_issuer_url
  namespace            = "default"
  service_account_name = "demo-workload"
  tags                 = local.common_tags
}
