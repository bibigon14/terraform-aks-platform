# Bootstrap

Manual Azure resources required before `terraform init` can run. Executed once per subscription.

## Prerequisites

- Azure CLI 2.50+ (`az --version`)
- An Azure subscription with Owner or User Access Administrator rights
- GitHub repo already created (this one)

## 1. Login

    az login --tenant <TENANT_ID>
    az account set --subscription <SUBSCRIPTION_ID>
    az account show

## 2. Register required resource providers

A fresh subscription has most namespaces unregistered. Register them before anything else - some AKS APIs will fail with `SubscriptionNotFound` otherwise, even though the subscription is enabled:

    az provider register -n Microsoft.Storage --wait
    az provider register -n Microsoft.ContainerService --wait
    az provider register -n Microsoft.ManagedIdentity --wait
    az provider register -n Microsoft.Network --wait

`Microsoft.Network` can take 10-30 minutes on a brand-new subscription. The rest usually complete in under 2 minutes. `--wait` blocks until each provider reaches `Registered`.

Verify:

    az provider list --query "[?namespace=='Microsoft.ContainerService' || namespace=='Microsoft.Network' || namespace=='Microsoft.ManagedIdentity' || namespace=='Microsoft.Storage']" -o table

## 3. Resource group and storage account for Terraform state

    export TF_RG=rg-aks-platform-tfstate
    export TF_STORAGE=stdstepanovtfstate$(openssl rand -hex 2)
    export TF_CONTAINER=tfstate
    export LOC=westus3

    az group create -n $TF_RG -l $LOC

    az storage account create \
      --name $TF_STORAGE \
      --resource-group $TF_RG \
      --location $LOC \
      --sku Standard_LRS \
      --kind StorageV2 \
      --min-tls-version TLS1_2 \
      --allow-blob-public-access false

    az storage container create \
      --name $TF_CONTAINER \
      --account-name $TF_STORAGE \
      --auth-mode login

Record `$TF_STORAGE` - the GitHub Actions workflows need it as a repository variable.

## 4. App Registration for GitHub OIDC

    export APP_NAME=terraform-aks-platform-deploy

    az ad app create --display-name $APP_NAME
    export APP_ID=$(az ad app list --display-name $APP_NAME --query '[0].appId' -o tsv)
    az ad sp create --id $APP_ID
    export SP_OBJECT_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query '[0].id' -o tsv)

## 5. Role assignments

    export SUB_ID=<SUBSCRIPTION_ID>

    az role assignment create \
      --assignee $APP_ID \
      --role "Contributor" \
      --scope "/subscriptions/$SUB_ID"

    az role assignment create \
      --assignee $APP_ID \
      --role "Role Based Access Control Administrator" \
      --scope "/subscriptions/$SUB_ID"

`Role Based Access Control Administrator` is needed because AKS deployment binds the Service Principal (and later a user-assigned Managed Identity) to the Azure RBAC-enabled cluster.

## 6. Federated credentials for GitHub Actions OIDC

Two federated credentials - one for PR plan runs, one for the production environment that gates apply/destroy:

    export GH_OWNER=bibigon14
    export GH_REPO=terraform-aks-platform

    cat > /tmp/fc-pr.json <<EOF
    {
      "name": "github-pr",
      "issuer": "https://token.actions.githubusercontent.com",
      "subject": "repo:${GH_OWNER}/${GH_REPO}:pull_request",
      "description": "GitHub Actions - PR plan runs",
      "audiences": ["api://AzureADTokenExchange"]
    }
    EOF
    az ad app federated-credential create --id $APP_ID --parameters /tmp/fc-pr.json

    cat > /tmp/fc-prod.json <<EOF
    {
      "name": "github-production",
      "issuer": "https://token.actions.githubusercontent.com",
      "subject": "repo:${GH_OWNER}/${GH_REPO}:environment:production",
      "description": "GitHub Actions - production apply/destroy",
      "audiences": ["api://AzureADTokenExchange"]
    }
    EOF
    az ad app federated-credential create --id $APP_ID --parameters /tmp/fc-prod.json

## 7. GitHub repository settings

### Secrets (Settings → Secrets and variables → Actions → New repository secret)

- `AZURE_CLIENT_ID` = `$APP_ID` from step 4
- `AZURE_TENANT_ID` = your tenant ID
- `AZURE_SUBSCRIPTION_ID` = your subscription ID

### Variables (Settings → Secrets and variables → Actions → Variables tab)

- `TF_STATE_RG` = `rg-aks-platform-tfstate`
- `TF_STATE_STORAGE` = `$TF_STORAGE` from step 3
- `TF_STATE_CONTAINER` = `tfstate`
- `TF_STATE_KEY` = `terraform.tfstate`

### Environment (Settings → Environments → New environment)

Create a `production` environment with a required reviewer gate (yourself). This matches the `environment:production` subject in the federated credential - without it, apply/destroy runs cannot acquire an Azure token.

## Verification

A successful bootstrap leaves:

- Resource group `rg-aks-platform-tfstate` in the chosen region
- Storage account with a `tfstate` blob container
- An App Registration named `terraform-aks-platform-deploy`
- Two role assignments at subscription scope
- Two federated credentials on the App Registration
- All four resource providers in `Registered` state

The next step is opening a PR with these Terraform files - the `plan` workflow should succeed on the Azure side with no local credentials involved.

## Teardown

    az ad app delete --id $APP_ID
    az group delete -n $TF_RG --yes --no-wait

The App Registration goes to a 30-day recycle bin before permanent deletion. If re-bootstrapping within that window, use `az ad app list --show-mine` and `az ad app restore --id` instead of creating a new one.
## OIDC subject claim format - gotcha

If `azure/login@v2` fails on the first PR plan run with:

    AADSTS700213: No matching federated identity record found for presented
    assertion subject 'repo:OWNER@USER_ID/REPO@REPO_ID:pull_request'

GitHub Actions is emitting a **customized** subject claim with embedded
numeric IDs instead of the documented `repo:OWNER/REPO:pull_request` form.
This happens on accounts (personal or organization) where GitHub has rolled
out immutable actor identifiers in the OIDC token.

Microsoft Learn and most example repos show the plain format - which Azure
AD then refuses because the actual presented claim does not match. The fix
is to register federated credentials with the exact subject the error
message prints, including the `@USER_ID` and `@REPO_ID` segments.

The three cross-cloud bootstraps hit identical gotchas:

- **AWS (EKS)** - CloudTrail event showed `repo:OWNER@ID/REPO@ID:ref:refs/...`
  being presented, STS AssumeRoleWithWebIdentity rejected the standard-format
  trust policy. Fix: trust policy condition had to match the actual sub.
- **GCP (GKE)** - Workload Identity Pool subject attribute mapping defaults
  to `assertion.sub`, same mismatch surfaced as
  `Error 400: identity pool subject does not match`.
- **Azure (AKS)** - this `AADSTS700213` error from `azure/login`.

### How to find the correct subject

The actual claim is in the Azure CLI error output under
`Federated token details`:

    Federated token details:
     issuer - https://token.actions.githubusercontent.com
     subject claim - repo:bibigon14@3174950/terraform-aks-platform@1405097511:pull_request
     audience - api://AzureADTokenExchange

Alternatively, extract from the GitHub token programmatically inside a
workflow:

    - name: Dump OIDC token subject
      run: |
        TOKEN=$(curl -sH "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
          "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" \
          | jq -r .value)
        echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | jq .sub

### Fix (delete + recreate - subject is immutable on an FC)

    export GH_USER_ID=3174950
    export GH_REPO_ID=1405097511

    az ad app federated-credential delete \
      --id $APP_ID \
      --federated-credential-id github-pr

    az ad app federated-credential delete \
      --id $APP_ID \
      --federated-credential-id github-production

    cat > /tmp/fc-pr.json <<EOF
    {
      "name": "github-pr",
      "issuer": "https://token.actions.githubusercontent.com",
      "subject": "repo:${GH_OWNER}@${GH_USER_ID}/${GH_REPO}@${GH_REPO_ID}:pull_request",
      "description": "GitHub Actions - PR plan runs",
      "audiences": ["api://AzureADTokenExchange"]
    }
    EOF
    az ad app federated-credential create --id $APP_ID --parameters /tmp/fc-pr.json

    cat > /tmp/fc-prod.json <<EOF
    {
      "name": "github-production",
      "issuer": "https://token.actions.githubusercontent.com",
      "subject": "repo:${GH_OWNER}@${GH_USER_ID}/${GH_REPO}@${GH_REPO_ID}:environment:production",
      "description": "GitHub Actions - production apply/destroy",
      "audiences": ["api://AzureADTokenExchange"]
    }
    EOF
    az ad app federated-credential create --id $APP_ID --parameters /tmp/fc-prod.json

A `gh run rerun <RUN_ID>` on the failed workflow is enough to re-trigger
without a dummy commit.

## Kubernetes version regional deprecation - gotcha

If `terraform apply` fails on first cluster creation with:

    Error: creating Kubernetes Cluster ...
    "code": "K8sVersionNotSupported",
    "message": "Managed cluster is on version 1.30.14 which is not supported
    in this region. Please use [az aks get-versions] command..."

The repo's `kubernetes_version` variable was set to a minor (`"1.30"`), AKS auto-selected the latest patch (`1.30.14`), and that patch has been deprecated in the chosen region.

AKS deprecates patch versions on a rolling schedule. A minor that is `GenerallyAvailable` globally can be `Deprecated` in a specific region within weeks. The `az aks get-versions` output is authoritative:

    az aks get-versions --location westus3 -o table | head -20

Pick a currently-supported minor from the top of that list and bump the variable:

    variable "kubernetes_version" {
      type    = string
      default = "1.35"
    }

Commit, push, re-approve the apply workflow.

## Free trial VM size restrictions - gotcha

If `terraform apply` fails during cluster creation with:

    "code": "BadRequest",
    "message": "The VM size of Standard_B2s is not allowed in your
    subscription in location 'westus3'. The available VM sizes are
    'standard_d128ds_v7,standard_d128lds_v7,...' [list of ~400 SKUs]
    For more details, please visit https://aka.ms/aks/quotas-skus-regions"

Free trial subscriptions explicitly deny the entire B-series (burstable, cheapest tier) in several regions. The allowed list includes every D-, E-, F-, HB-, L-, M-, NC- and NV-series SKU - just not the cheap one most AKS quickstarts default to.

Pick a D-series equivalent that is on the allowed list and under the free trial budget. `Standard_D2s_v4` is a good default: 2 vCPU, 8 GB RAM, ~$0.10/hr on-demand, present in every US region's free-trial allowlist.

    variable "node_vm_size" {
      type    = string
      default = "Standard_D2s_v4"
    }

A pay-as-you-go subscription has no such restriction - B-series is normally cheapest. If you upgrade off the free trial, bump this back down for cost.

## AAD-enabled AKS requires kubelogin - gotcha

Right after `az aks get-credentials`, `kubectl` fails with:

    Unable to connect to the server: getting credentials: exec: executable
    kubelogin not found

    It looks like you are trying to use a client-go credential plugin that
    is not installed.

    kubelogin is not installed which is required to connect to AAD enabled
    cluster.

AKS clusters with `azure_active_directory_role_based_access_control` enabled (which this repo does) authenticate via Azure AD. The kubeconfig that `az aks get-credentials` writes expects a `kubelogin` binary to be on PATH to broker the AAD token exchange.

Install:

    # recommended on macOS
    brew install Azure/kubelogin/kubelogin

    # or via az (writes to /usr/local/bin, may need sudo)
    az aks install-cli

Then convert the kubeconfig to use the current Azure CLI session instead of interactive device-code login:

    kubelogin convert-kubeconfig -l azurecli

After this, `kubectl` picks up a token from `az login` silently. The `--admin` flag on `az aks get-credentials` is a fallback that bypasses AAD and uses cluster-local certificates, but it does not respect Azure RBAC and should not be used past bootstrap.

## Self-service RBAC admin bootstrap - gotcha

After `kubelogin convert-kubeconfig`, `kubectl get nodes` returns:

    Error from server (Forbidden): nodes is forbidden: User
    "<your-object-id>" cannot list resource "nodes" in API group "" at
    the cluster scope: User does not have access to the resource in Azure.
    Update role assignment to allow access.

With `azure_rbac_enabled = true` and `admin_group_object_ids = []`, nobody has cluster-level roles by default. The Terraform deploy service principal has `Role Based Access Control Administrator` at subscription scope (it can grant roles) but has no cluster role of its own, and neither does the signed-in user.

Grant yourself cluster admin on just this cluster:

    USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
    CLUSTER_ID=$(az aks show -g rg-aks-platform-demo -n aks-aks-platform-demo --query id -o tsv)

    az role assignment create \
      --assignee $USER_OBJECT_ID \
      --role "Azure Kubernetes Service RBAC Cluster Admin" \
      --scope $CLUSTER_ID

Azure RBAC propagation is 2 to 5 minutes. If `kubectl get nodes` still returns 403 after assignment, wait and retry rather than re-granting.

For teams, replace this manual step with an Entra ID group whose members get the role automatically. Pass the group's object ID to `admin_group_object_ids` in `terraform.tfvars` and let Terraform create the role assignment itself:

    variable "admin_group_object_ids" {
      type    = list(string)
      default = ["00000000-0000-0000-0000-000000000000"]  # your Entra ID group
    }

## Full gotcha chain summary

One bootstrap of this repo against a fresh free-trial Azure subscription surfaced five distinct failures that any production-grade AKS deploy pattern will eventually have to answer. In chronological order:

| # | Where | Failure | Root cause | Fix |
|---|-------|---------|------------|-----|
| 1 | PR `plan` | `AADSTS700213: No matching federated identity record` | GitHub emits customized OIDC subject with `@USER_ID/REPO@REPO_ID` segments; FC registered with the documented bare `OWNER/REPO` form | Delete + recreate FCs with the actual subject the error prints |
| 2 | `apply` #1 | `K8sVersionNotSupported` version 1.30.14 | AKS auto-resolved `kubernetes_version="1.30"` to a patch that is deprecated in `westus3` | Bump minor to a currently-supported one (`az aks get-versions`) |
| 3 | `apply` #2 | `BadRequest: Standard_B2s not allowed` | Free trial subscriptions deny B-series in several regions | Use `Standard_D2s_v4` or any other on-allowlist SKU |
| 4 | post-deploy | `kubelogin not found` | AAD-enabled clusters write kubeconfigs that require `kubelogin` for token exchange | `brew install kubelogin` + `kubelogin convert-kubeconfig -l azurecli` |
| 5 | post-deploy | `Forbidden: User does not have access` | Nobody has cluster-level Azure RBAC role; deploy SP can grant but has no cluster role itself | `az role assignment create` for `Azure Kubernetes Service RBAC Cluster Admin` on current user |

Four of five were caught by CI before any resource was actually created or in a bad state. The fifth is a post-deploy user-side setup, not a cluster health issue. None of the five is documented in a single place in Microsoft's AKS quickstart.
