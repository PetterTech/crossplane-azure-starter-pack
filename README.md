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

Compositions only use standard functions (environment-configs, patch-and-transform, kro, go-templating, sequencer, auto-ready). There are no custom functions.

## Getting started

You need a Kubernetes cluster and an Azure environment you can deploy to. That's it. Then:

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
4. Create a `ClusterProviderConfig` named `default` that points to that identity
   ([template](crossplane/templates/cluster-provider-config.yaml)). Its
   `spec.subscriptionID` and `EnvironmentConfig.data.identityResourceGroupName`
   select where Space identities are created.
5. Create an `EnvironmentConfig` named `azure` with your tenant, default region,
   identity resource group, billing scope and corp/online management groups
   ([template](crossplane/templates/environment-config.yaml)).
6. Apply the XRDs and compositions from `projects/foundation`, then `projects/services`, then `projects/stacks`.
7. Start creating XRs in your team namespaces.

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

The service account name `provider-azure` is set in
`crossplane/deployment-runtime-config.yaml` and the Space composition.
Keep both and the federated credential subject above in sync.

Then give the central identity access for subscription vending:

- **Managed Identity Contributor** on the central identity resource group.
- **Management Group Contributor** on the target corp and online management
  groups, or a suitable shared ancestor.
- Permission to create subscriptions in your billing account. This can't be done with `az role assignment`, see [Create subscriptions programmatically](https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/programmatically-create-subscription)

```shell
az role assignment create \
  --assignee-object-id <principalId> \
  --assignee-principal-type ServicePrincipal \
  --role "Management Group Contributor" \
  --scope /providers/Microsoft.Management/managementGroups/<management-group-id>
```

Repeat for the other target group, or use an appropriate shared ancestor.

Not on AKS? Any cluster with a public OIDC issuer works the same way. See [Workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation).

## Before you use this for real

- Replace `platform.example.org` with your own domain and fill in the platform templates.
- Think through identity: which identity each team gets, and what it is allowed to do.
- Lock down what teams can create. Teams should only get access to your platform APIs, not to provider resources or ProviderConfigs.

## XRDs

### Space

A [Space](projects/foundation/apis/space/definition.yaml) creates a subscription,
a managed identity in the central Azure resource group, and a ProviderConfig in
the Space's namespace. The identity has **Owner only on that subscription**.

Public inputs are `displayName`, `exposure` and optional `tags`:

- `private` places the subscription in corp; `public` places it in online.
  The composition maps exposure to `managementGroupIds.corp` or `.online`.
- Managed identities use the platform's shared `defaultLocation`.
- Exposure is immutable. It controls governance placement, not network access.
- Up to 40 user tags are merged with up to 10 platform tags from EnvironmentConfig.
  Platform-owned values override matching keys, ignoring case as Azure does.

Try the [private](projects/foundation/examples/space-private.yaml) or
[public](projects/foundation/examples/space-public.yaml) example in `team-a`.
Wait for `Ready=True` before deploying services. Services select a Space by name
in the same namespace and use its `status.providerConfigName`; callers do not
choose credentials. Only platform controllers should write ProviderConfigs,
managed resources or XR status; the namespace does not isolate Azure identities
from the shared provider service account.

The central identity bootstraps the subscription, management-group association,
identity, federation and Owner assignment. Resource-provider registrations use the
Space identity: Microsoft.Network, Microsoft.Storage, Microsoft.KeyVault,
Microsoft.Compute and Microsoft.App.

Delete with `kubectl delete space <name> -n <namespace> --cascade=foreground`.
Deletion cancels the subscription and removes the managed identity and its access.
Crossplane does not remove the management-group association or unregister
providers; they remain for the subscription's lifetime. Sequenced Usages preserve
credentials until dependent resources are removed. Delete service XRs before
deleting their Space.

#### Checking Space locally

The [fixtures](projects/foundation/tests/space) use synthetic IDs, not a live tenant.
With the Crossplane CLI and Docker, render each example from the repository root:

```shell
crossplane render projects/foundation/examples/space-private.yaml \
  projects/foundation/apis/space/composition.yaml crossplane/functions.yaml \
  --crossplane-version=v2.4.3 \
  --xrd=projects/foundation/apis/space/definition.yaml \
  --required-resources=projects/foundation/tests/space/environment.yaml
```

Repeat with `space-public.yaml`. An initial render only creates the subscription
and identity. To render the completed composition, use
`projects/foundation/tests/space/xr-ready.yaml` as the XR and add
`--observed-resources=projects/foundation/tests/space/observed-ready.yaml`.
It should contain all five provider registrations and namespaced v2 Usages.

Validate examples with `crossplane resource validate
projects/foundation/apis/space/definition.yaml projects/foundation/examples`.
Validate rendered output against that XRD, the pinned provider CRDs and Crossplane's
Usage CRD. Rendering does not test Azure permissions, role propagation or deletion.

## License

MIT
