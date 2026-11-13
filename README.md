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
   identity resource group, billing scope, management groups, pool, hub and
   platform identity principal ID
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
- **Role Based Access Control Administrator** on the IPAM pool, with a condition
  permitting only creation and deletion of **IPAM Pool User** assignments.
- **Network Contributor** on the hub resource group, for hub connections.
- Permission to create subscriptions in your billing account. This can't be done with `az role assignment`, see [Create subscriptions programmatically](https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/programmatically-create-subscription)

```shell
az role assignment create \
  --assignee-object-id <principalId> \
  --assignee-principal-type ServicePrincipal \
  --role "Management Group Contributor" \
  --scope /providers/Microsoft.Management/managementGroups/<management-group-id>
```

Repeat for the other target group, or use an appropriate shared ancestor.

For the pool, use a [delegation condition][delegation-conditions] that restricts
both creation and deletion to IPAM Pool User. Crossplane needs delete access to
remove a Space's pool assignment when that Space is deleted.

```shell
az role assignment create \
  --assignee-object-id <principalId> \
  --assignee-principal-type ServicePrincipal \
  --role "Role Based Access Control Administrator" \
  --scope <ipam-pool-resource-id> \
  --condition "(
    (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
    )
    OR
    (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId]
      ForAnyOfAnyValues:GuidEquals {7b3e853f-ad5d-4fb5-a7b8-56a3581c7037}
    )
  )
  AND
  (
    (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
    )
    OR
    (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId]
      ForAnyOfAnyValues:GuidEquals {7b3e853f-ad5d-4fb5-a7b8-56a3581c7037}
    )
  )" \
  --condition-version 2.0
```

[delegation-conditions]: https://learn.microsoft.com/en-us/azure/role-based-access-control/delegate-role-assignments-overview#how-to-delegate-role-assignment-management-with-conditions

Not on AKS? Any cluster with a public OIDC issuer works the same way. See [Workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation).

## Before you use this for real

- Replace `platform.example.org` with your own domain and fill in the platform templates.
- Think through identity: which identity each team gets, and what it is allowed to do.
- Lock down what teams can create. Teams should only get access to your platform APIs, not to provider resources or ProviderConfigs.
- A closed Bucket account requires the cluster to reach its private endpoint for
  provider data-plane calls. Azure Landing Zones policies that deny public network
  access will block Bucket.

## Local checks

With PowerShell 7, the Crossplane CLI and Docker running, run from the repository root:

```shell
pwsh -NoProfile -File ./tests/test.ps1
```

The [test runner](tests/test.ps1) runs with PowerShell 7 on Windows, Linux and macOS.
It renders all Space, Network, Bucket and SecretStore examples plus ready-state
fixtures, then validates examples and output against the XRDs, pinned providers
and Crossplane schemas.
Missing schemas and failed checks return a nonzero exit code.
Temporary output is removed; downloaded provider schemas and Docker images are cached.
Each run fetches the namespaced Usage CRD from the pinned Crossplane release on GitHub;
the first run also needs registry access. No cluster or Azure credentials are needed.
These checks do not test live Azure behavior.

## XRDs

### Space

A [Space](projects/foundation/apis/space/definition.yaml) creates a subscription,
a managed identity in the central Azure resource group, and a ProviderConfig in
the Space's namespace. The identity has **Owner** on that subscription and
**IPAM Pool User** on the platform pool.

Public inputs are `displayName`, `exposure` and optional `tags`:

- `private` places the subscription in corp; `public` places it in online.
  The composition maps exposure to `managementGroupIds.corp` or `.online`.
- Managed identities use the platform's shared `defaultLocation`.
- Exposure is immutable. It controls governance placement, not network access.
- Up to 40 user tags are merged with up to 10 platform tags from EnvironmentConfig.
  Platform-owned values take precedence over user tags with matching keys.
  Space matches tag keys case-insensitively.

Try the [private](projects/foundation/examples/space-private.yaml) or
[public](projects/foundation/examples/space-public.yaml) example in `team-a`.
Wait for `Ready=True` before deploying services. Services select a Space, by
name or through a Network in the same namespace, and use its
`status.providerConfigName`; callers do not
choose credentials. Only platform controllers should write ProviderConfigs,
managed resources or XR status; the namespace does not isolate Azure identities
from the shared provider service account.

The central identity bootstraps the subscription, management-group association,
identity, federation, Owner assignment and pool access. Resource-provider
registrations use the Space identity: Microsoft.Network, Microsoft.Storage,
Microsoft.KeyVault, Microsoft.Compute and Microsoft.App.

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

Validate the Space examples with `crossplane resource validate
projects/foundation/apis/space/definition.yaml
projects/foundation/examples/space-private.yaml,projects/foundation/examples/space-public.yaml`.
Validate rendered output against that XRD, the pinned provider CRDs and Crossplane's
Usage CRD. Rendering does not test Azure permissions, role propagation or deletion.

### Network

A [Network](projects/foundation/apis/network/definition.yaml) selects a
Space by name in the same namespace. It owns a resource group, an IPAM-backed
VNet, one subnet using the entire allocation, and an attached NSG with **no custom
rules**. Azure default NSG rules still apply; this is not spoke isolation.

The resource group is named `network-<metadata.name>`, so its name stays stable
when the cluster is rebuilt from Git.

Inputs are `space`, `size` (small `/25`, medium `/24`, large `/23`; default medium)
and optional `tags`. Space and size are immutable.
Platform-owned values take precedence over user tags with matching keys.
Network matches tag keys exactly. There are no credential, subnet or hub switches.
App infrastructure subnets are out of scope.

Networks in private Spaces connect to the platform Virtual WAN hub. Networks in
public Spaces do not; this does not automatically expose them to the Internet.
See the [private](projects/foundation/examples/network-private.yaml) and
[public](projects/foundation/examples/network-public.yaml) examples.

#### Network identity and setup

The Space identity creates all resources in its subscription, including the
VNet and, for private Spaces, a **Network Contributor** assignment for the
platform identity scoped to that VNet. The platform identity uses
ClusterProviderConfig `default` to create the hub connection. Space identities
have no hub access.

Set `ipamPoolID`, `virtualHubID` and `platformPrincipalID` in the
[environment template](crossplane/templates/environment-config.yaml). The
principal ID must match ClusterProviderConfig `default`. Pool, hub and region
are platform settings, not pinned per Network: changing them affects existing
Networks and requires a planned migration.

The shared hub does not isolate team networks. Configure hub routing before
production, and use quotas and pool monitoring to manage IP address exhaustion.

Sequenced v2 Usages preserve the VNet grant until its hub connection is removed.
A Usage protects the selected Space until
Network cleanup completes. Neither the central pool nor hub is owned or deleted.

#### Checking Network locally

The [fixtures](projects/foundation/tests/network) contain synthetic IDs.
Render each example from the repository root:

```shell
crossplane render projects/foundation/examples/network-private.yaml \
  projects/foundation/apis/network/composition.yaml crossplane/functions.yaml \
  --crossplane-version=v2.4.3 \
  --xrd=projects/foundation/apis/network/definition.yaml \
  --required-resources=projects/foundation/tests/network/environment.yaml \
  --observed-resources=projects/foundation/tests/network/observed-ready.yaml \
  --include-full-xr
```

Repeat with `network-public.yaml` and
`projects/foundation/tests/network/observed-public.yaml`.
The private graph includes the hub connection and dependency Usages. Validate examples
against the Network XRD, and full render output against that XRD, the pinned
provider CRDs and Crossplane's v2 Usage CRD.
Rendering does not verify Azure permissions, RBAC propagation, routing or deletion.

### Bucket

A [Bucket](projects/services/apis/bucket/definition.yaml) is blob
storage. It selects a Network by name in the same namespace and uses that
Network's Space and subnet. It owns a resource group named
`bucket-<metadata.name>`, a storage account, one private container per entry
and a blob private endpoint in the Network subnet.

Inputs are `network`, `containers` (1-20 names), `geoRedundant` and optional
`tags`. `geoRedundant: false` (default) keeps copies in three zones (ZRS);
`true` also copies asynchronously to the paired region (GZRS). Network and
geoRedundant are immutable. Platform-owned tags take precedence over user tags
with matching keys.

The account has a public endpoint because the provider must reach the data plane
on create and every read. Access is Microsoft Entra ID only (no shared keys or
anonymous access); apps should use the private endpoint. TLS 1.2, blob versioning
and 7 days of soft delete are fixed. Its name is `st` plus a hash of subscription,
namespace and name, shown in `status.accountName`. Grant data access with Azure RBAC, for example
**Storage Blob Data Contributor** on `status.resourceID`.

All resources use the Space's ProviderConfig. The composition does not create
private DNS records; it relies on the Azure Landing Zones DeployIfNotExists policy
for `privatelink.blob.core.windows.net`. Without that policy, configure DNS yourself.
The Network and its Space must have their subnet and identity outputs available.
Missing dependencies or empty status outputs fail reconciliation without
dropping existing composed resources.

Deleting a Bucket deletes the storage account and all its data. Removing a
container from the list deletes that container. A Usage keeps the Network, and
through it the Space, until Bucket cleanup completes.
See the [example](projects/services/examples/bucket.yaml).

#### Checking Bucket locally

```shell
crossplane render projects/services/examples/bucket.yaml \
  projects/services/apis/bucket/composition.yaml crossplane/functions.yaml \
  --crossplane-version=v2.4.3 \
  --xrd=projects/services/apis/bucket/definition.yaml \
  --required-resources=projects/services/tests/bucket/environment.yaml \
  --observed-resources=projects/services/tests/bucket/observed-ready.yaml \
  --include-full-xr
```

Without `--observed-resources` only the Network Usage is created; the rest
follows once it is ready. The test runner also checks dependency failures and
container input limits. Rendering does not verify Azure permissions, DNS or
deletion.

### SecretStore

A [SecretStore](projects/services/apis/secretstore/definition.yaml) is a
private Key Vault. It selects a Network by name in the same namespace and uses
that Network's Space and subnet. It owns a resource group named
`secretstore-<metadata.name>`, a vault and a vault private endpoint in the
Network subnet.

Inputs are `network` (immutable) and optional `tags`. Platform-owned tags take
precedence over user tags with matching keys. Region and tenant come from
EnvironmentConfig.

Hardening is fixed: standard SKU, Azure RBAC only, public network access off,
no trusted-services bypass, purge protection and 90 days of soft delete. VM,
disk encryption and template deployment access are off. Its name is `kv` plus a
hash of subscription, namespace and name, shown in `status.vaultName`.

The API creates no secrets, keys, certificates or role assignments. Grant data
access with Azure RBAC, for example **Key Vault Secrets User** on
`status.resourceID`. All resources use the Space's ProviderConfig. The
composition does not create private DNS records; it relies on the Azure Landing
Zones DeployIfNotExists policy for `privatelink.vaultcore.azure.net`. Without
that policy, configure DNS yourself. Missing dependencies or empty status
outputs fail reconciliation without dropping existing composed resources.

Deleting a SecretStore deletes the endpoint, vault and resource group. Purge
protection keeps the vault and its contents soft-deleted and recoverable for 90
days, and its name stays reserved; recovery does not restore role assignments.
A Usage keeps the Network, and through it the Space, until cleanup completes.
See the [example](projects/services/examples/secretstore.yaml).

#### Checking SecretStore locally

```shell
crossplane render projects/services/examples/secretstore.yaml \
  projects/services/apis/secretstore/composition.yaml \
  crossplane/functions.yaml \
  --crossplane-version=v2.4.3 \
  --xrd=projects/services/apis/secretstore/definition.yaml \
  --required-resources=projects/services/tests/secretstore/environment.yaml \
  --observed-resources=projects/services/tests/secretstore/observed-ready.yaml \
  --include-full-xr
```

Without `--observed-resources` only the Network Usage is created; the rest
follows once it is ready. The test runner also checks dependency failures.
Rendering does not verify Azure permissions, DNS, recovery or deletion.

## License

MIT
