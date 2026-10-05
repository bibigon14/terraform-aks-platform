# terraform-aks-platform

Portfolio project: a production-shaped AKS-on-Azure platform, provisioned end-to-end with Terraform and GitHub Actions - no local `terraform apply` in the loop.

Designed to be `apply`ed, demoed, and `destroy`ed the same day. Not a long-running install.

Companion to [terraform-eks-platform](https://github.com/bibigon14/terraform-eks-platform) and [terraform-gke-platform](https://github.com/bibigon14/terraform-gke-platform) - same shape, different cloud.

## Real bug caught by CI

The first PR plan run on this repo failed inside `azure/login` with:

```
Federated token details:
 subject claim - repo:bibigon14@3174950/terraform-aks-platform@1405097511:pull_request

##[error]AADSTS700213: No matching federated identity record found for
presented assertion subject
'repo:bibigon14@3174950/terraform-aks-platform@1405097511:pull_request'.
```

The federated credentials had been created from the documented subject format - `repo:OWNER/REPO:pull_request` - but GitHub Actions on this account was emitting a **customized** claim with embedded user and repo IDs: `repo:OWNER@USER_ID/REPO@REPO_ID:pull_request`. Azure AD refused the token because the subject on the FC did not match the subject in the presented assertion.

**Root cause**. GitHub is rolling out immutable actor identifiers in OIDC tokens to accounts over time - personal and organization both. When the feature is active for an account, the plain `repo:OWNER/REPO:...` subject documented in every Azure quickstart does not match the claim that is actually presented. There is no override on the GitHub side; the fix is to register federated credentials with the exact subject the Azure CLI error prints.

Remediation (delete + recreate - subject is immutable on an existing FC) is documented in [bootstrap.md](bootstrap.md#oidc-subject-claim-format---gotcha).

**Why this matters**. Local `terraform plan` and `validate` are both clean. The bug lives in the gap between CI-side OIDC token minting and Azure AD's federated-identity matching - a layer no local tool exercises. Catching it at PR plan time left the stack in a clean state; without the plan gate, the same error would have surfaced on `terraform apply` after the resource group and storage account were already changing.

The same claim-format drift has fired on all three cross-cloud bootstraps in this portfolio - AWS (STS `AssumeRoleWithWebIdentity`), GCP (Workload Identity Pool subject attribute mapping), and now Azure. The surfaces are different, the root cause is one.

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
