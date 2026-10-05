# terraform-aks-platform

Portfolio project: a production-shaped AKS-on-Azure platform, provisioned end-to-end with Terraform and GitHub Actions - no local `terraform apply` in the loop.

Designed to be `apply`ed, demoed, and `destroy`ed the same day. Not a long-running install.

Companion to [terraform-eks-platform](https://github.com/bibigon14/terraform-eks-platform) and [terraform-gke-platform](https://github.com/bibigon14/terraform-gke-platform) - same shape, different cloud.

## Walkthrough

_TODO: Added after first clean end-to-end apply._

## Architecture

```
GitHub PR  ─────────────────────────────────┐
                                            │
                                   plan.yml (OIDC)
                                            │
                                            ▼
                                  ┌──────────────────┐
                                  │  Azure App Reg   │
                                  │  (federated SP)  │
                                  └────────┬─────────┘
                                           │
                                           ▼
                            ┌───────────────────────────────┐
                            │  Terraform state in           │
                            │  Azure Blob (sanitized backend) │
                            └───────────────┬───────────────┘
                                            │
                     push to main → apply.yml (production env gated)
                                            │
                                            ▼
                            ┌───────────────────────────────┐
                            │  Resource Group               │
                            │   └─ AKS cluster              │
                            │       ├─ OIDC issuer          │
                            │       ├─ Workload Identity    │
                            │       └─ Azure RBAC           │
                            │   └─ User-assigned Managed    │
                            │      Identity (federated to a │
                            │      k8s ServiceAccount)      │
                            └───────────────────────────────┘
```

## Bootstrap

Manual steps to prepare Azure for Terraform are in [`bootstrap.md`](bootstrap.md). Run once per subscription:

- Register resource providers (`Microsoft.ContainerService`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.ManagedIdentity`)
- Resource group and storage account for Terraform state
- App Registration and federated credentials for GitHub OIDC
- Role assignments on the subscription (`Contributor` + `Role Based Access Control Administrator`)
- GitHub repo secrets, variables, and the `production` environment with a reviewer gate

Once bootstrap is done, all `plan` / `apply` / `destroy` happens through the workflows in [`.github/workflows/`](.github/workflows/) - triggered by PRs (plan), merges to `main` (apply, gated by the `production` environment reviewer), and manual dispatch (destroy).

## Cost and lifecycle

Full apply → demo → destroy cycle typically completes in under 25 minutes and costs under $2 on the Azure $200 free trial credit. AKS control plane is free; two `Standard_B2s` nodes at roughly $0.03/hr each account for most of the bill.

## Workload Identity demo

The main module provisions a user-assigned Managed Identity federated to a Kubernetes ServiceAccount at `default/demo-workload`. To use it from inside the cluster:

1. Create the namespace and ServiceAccount with the `azure.workload.identity/client-id` annotation set to the `workload_identity_demo_client_id` output
2. Add the `azure.workload.identity/use: "true"` label to any pod that should assume this identity
3. Give the Managed Identity whatever Azure RBAC it needs (e.g., `Key Vault Secrets User` on a Key Vault) via `azurerm_role_assignment` outside this module

That gives a pod the ability to call Azure APIs with no secret, no password, no service principal key in the cluster.

## Follow-ups (v2 backlog)

- Scope the deploy service principal from `Contributor` down to per-resource permissions
- Private AKS cluster (`private_cluster_enabled = true` with Private Link to the API server)
- `tflint` + `trivy` in CI
- Pre-commit hooks with `terraform fmt` + `terraform validate`
- Container Insights via a Log Analytics workspace
- A real demo workload (Kubernetes Deployment + Service) using the Managed Identity to read from Key Vault
- Separate state keys for a networking-only module and a cluster-only module, so one can be redeployed without the other
