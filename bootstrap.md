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
