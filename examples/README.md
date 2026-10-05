# examples/

End-to-end demonstrations that use the AKS cluster this repo provisions.

Each example assumes `terraform apply` on the root module completed and you have `kubectl` configured against the cluster.

## workload-identity-demo.yaml

A minimal pod that proves the Azure Workload Identity federation is working: a projected ServiceAccount token is exchanged by Azure AD for a Managed Identity access token, with no secret stored in the cluster.

Apply:

    CLIENT_ID=$(terraform output -raw workload_identity_demo_client_id)
    sed "s/__CLIENT_ID__/$CLIENT_ID/" examples/workload-identity-demo.yaml | kubectl apply -f -

Watch the login succeed:

    kubectl logs -n default deploy/wi-demo

A healthy run shows `az account show` returning the Managed Identity (type `user`, with `homeTenantId` matching your subscription's tenant). Inside the container, only the projected token file lives on disk - no `AZURE_CLIENT_SECRET`, no key material.

Cleanup:

    kubectl delete -f examples/workload-identity-demo.yaml
