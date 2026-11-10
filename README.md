# crossplane-azure-starter-pack

A starting point for building an internal platform on Azure with Crossplane.

This is an accelerator, not a product. Fork it, read it, change it. Nothing here is production ready as-is, and it is meant to be simple enough that you understand all of it before you use any of it.

The landing zone follows the same model as Microsoft's Azure Landing Zones and subscription vending, so it should feel familiar if you know CAF, and give you a CAF-aligned starting point if you don't.

## What's in here

```
crossplane/            Providers, functions and runtime config to install into the cluster
projects/foundation/   Space and network: the building blocks of a landing zone
projects/services/     Single resources teams use inside their landing zone
projects/stacks/       APIs that combine other APIs, like LandingZone
```

Each project is a Crossplane CLI project with its own `crossplane-project.yaml`, an `apis/` folder with one XRD and composition per API, and `examples/`.

APIs:

- foundation: `Space` (subscription, management group, identity), `Network` (VNet and hub connection)
- services: `Bucket` (storage account), `SecretStore` (Key Vault), `App` (container app)
- stacks: `LandingZone` (a `Space` and a `Network`)

Compositions only use standard functions (patch-and-transform, kro, go-templating, sequencer, auto-ready). There are no custom functions.

## Getting started

You need a Kubernetes cluster and an Azure environment you can deploy to. That's it.

1. Install Crossplane v2 ([docs](https://docs.crossplane.io/latest/get-started/install/)):

   ```shell
   helm repo add crossplane-stable https://charts.crossplane.io/stable
   helm repo update
   helm install crossplane crossplane-stable/crossplane \
     --namespace crossplane-system --create-namespace \
     --version 2.4.3
   ```

2. Then [give Crossplane an identity and access in Azure](#identity-and-access-on-aks).
3. Apply `crossplane/` (runtime config, providers, functions) and wait until everything is healthy.
4. Create a `ClusterProviderConfig` named `default` that points to that identity.
5. Apply the XRDs and compositions from `projects/foundation`, then `projects/services`, then `projects/stacks`.
6. Try something from a project's `examples/`.

## Identity and access on AKS

Crossplane talks to Azure with Workload Identity: a managed identity that trusts the providers' Kubernetes service account. No secrets.

```shell
RG=<resource group of the cluster>
CLUSTER=<cluster name>

# Turn on OIDC issuer and Workload Identity
az aks update -g $RG -n $CLUSTER --enable-oidc-issuer --enable-workload-identity
ISSUER=$(az aks show -g $RG -n $CLUSTER --query oidcIssuerProfile.issuerUrl -o tsv)

# Create the identity and let the provider service account use it
az identity create -g $RG -n crossplane
az identity federated-credential create -g $RG --identity-name crossplane \
  --name provider-azure \
  --issuer $ISSUER \
  --subject system:serviceaccount:crossplane-system:provider-azure \
  --audience api://AzureADTokenExchange

# You need these for the ClusterProviderConfig
az identity show -g $RG -n crossplane --query "{clientId:clientId, principalId:principalId, tenantId:tenantId}"
```

The service account name `provider-azure` comes from `crossplane/deployment-runtime-config.yaml`. If you change one, change the other.

Then give the identity access. For subscription vending it needs:

- **Contributor** and **Role Based Access Control Administrator** on the management group where landing zones go
- **Network Contributor** on the hub VNet, for peering
- Permission to create subscriptions in your billing account. This can't be done with `az role assignment`, see [Create subscriptions programmatically](https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/programmatically-create-subscription)

```shell
az role assignment create --assignee-object-id <principalId> --assignee-principal-type ServicePrincipal \
  --role Contributor --scope /providers/Microsoft.Management/managementGroups/<landing zones MG>
```

Not on AKS? Any cluster with a public OIDC issuer works the same way. See [Workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation).

## Before you use this for real

- Replace `platform.example.org` and the IDs in the compositions with your own.
- Think through identity: which identity each team gets, and what it is allowed to do.
- Lock down what teams can create. Teams should only get access to your platform APIs, not to provider resources or ProviderConfigs.

## License

MIT
