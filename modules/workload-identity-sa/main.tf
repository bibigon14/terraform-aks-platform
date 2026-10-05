# Azure counterpart of EKS's IRSA and GKE's Workload Identity Federation.
#
# A user-assigned Managed Identity is federated with the AKS cluster's OIDC
# issuer, scoped to one Kubernetes ServiceAccount. Pods running under that
# SA (with proper annotation) exchange their projected token for an Azure AD
# token tied to this identity - no secret, no password, no service principal
# key material anywhere in the cluster.

resource "azurerm_user_assigned_identity" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "this" {
  name      = "${var.name}-federated-credential"
  parent_id = azurerm_user_assigned_identity.this.id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = var.oidc_issuer_url
  subject   = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
}
