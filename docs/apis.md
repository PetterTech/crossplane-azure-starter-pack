# APIs

Reference for every API in the starter pack: what it creates, its inputs, what
it publishes in status and what happens when you delete it. For a guided first
deployment, see [Deploy your first LandingZone](deployment.md). For rendering
APIs locally, see [Local checks](../tests/README.md).

All APIs are namespaced and live in the `platform.example.org` group. Replace
that group with your own domain before real use.

- [Space](#space) and [Network](#network) (foundation)
- [Bucket](#bucket), [SecretStore](#secretstore) and [App](#app) (services)
- [LandingZone](#landingzone) (stacks)

A note on the word "exposure": on Space and LandingZone it selects
**governance placement** (corp or online management group). It does not open or
close anything on the network. Only App has a network exposure setting.

All six APIs require lowercase tag keys because Azure treats tag names
case-insensitively while map merges do not. Tag values are passed through
unchanged. Existing manifests with uppercase tag keys must be updated before
applying the APIs.

## Space

A [Space](../projects/foundation/apis/space/definition.yaml) creates a subscription,
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
  `platformTags` keys must also be lowercase.

Try the [private](../projects/foundation/examples/space-private.yaml) or
[public](../projects/foundation/examples/space-public.yaml) example in `team-a`.
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

Status publishes `subscriptionID`, `providerConfigName` and the identity's
`resourceID`, `clientID` and `principalID`.

Delete with `kubectl delete space <name> -n <namespace> --cascade=foreground`.
Deletion removes the managed identity and its access, and deletes the Subscription
resource, which is meant to cancel the subscription. That cancellation hasn't
been verified against Azure yet.
Crossplane does not remove the management-group association or unregister
providers; they remain for the subscription's lifetime. Sequenced Usages preserve
credentials until dependent resources are removed. Delete service XRs before
deleting their Space.

## Network

A [Network](../projects/foundation/apis/network/definition.yaml) selects a
Space by name in the same namespace. It owns a resource group, an IPAM-backed
VNet, one subnet using the entire allocation, and an attached NSG with **no custom
rules**. Azure default NSG rules still apply; this is not spoke isolation.

The resource group is named `network-<metadata.name>`, so its name stays stable
when the cluster is rebuilt from Git. The VNet and NSG are named `network`, the
subnet `default`.

Inputs are `space`, `size` (small `/25`, medium `/24`, large `/23`; default medium)
and optional `tags`. Space and size are immutable. Platform-owned values take
precedence over user tags with matching keys. There are no credential, subnet or
hub switches.
App infrastructure subnets are out of scope.

Networks in private Spaces connect to the platform Virtual WAN hub. Networks in
public Spaces do not; this does not automatically expose them to the Internet.
See the [private](../projects/foundation/examples/network-private.yaml) and
[public](../projects/foundation/examples/network-public.yaml) examples.

Status publishes `resourceID`, `addressSpace` and `subnetID`.

### Network identity and setup

The Space identity creates all resources in its subscription, including the
VNet and, for private Spaces, a **Network Contributor** assignment for the
platform identity scoped to that VNet. The platform identity uses
ClusterProviderConfig `default` to create the hub connection. Space identities
have no hub access.

Set `ipamPoolID`, `virtualHubID` and `platformPrincipalID` in the
[environment template](../crossplane/templates/environment-config.yaml). The
principal ID must match ClusterProviderConfig `default`. Pool, hub and region
are platform settings, not pinned per Network: changing them affects existing
Networks and requires a planned migration.

The shared hub does not isolate team networks. Configure hub routing before
production, and use quotas and pool monitoring to manage IP address exhaustion.

Sequenced v2 Usages preserve the VNet grant until its hub connection is removed.
A Usage protects the selected Space until
Network cleanup completes. Neither the central pool nor hub is owned or deleted.

## Bucket

A [Bucket](../projects/services/apis/bucket/definition.yaml) is blob
storage. It selects a Network by name in the same namespace and uses that
Network's Space and subnet. It owns a resource group named
`bucket-<metadata.name>`, a storage account, one private container per entry
and a blob private endpoint in the Network subnet.

Inputs are `network`, `containers` (1-20 names), `geoRedundant` and optional
`tags`. `geoRedundant: false` (default) keeps copies in three zones (ZRS);
`true` also copies asynchronously to the paired region (GZRS). Network and
geoRedundant are immutable. Platform-owned tags take precedence over user tags
with matching keys. Tag keys must be lowercase.

The account has a public endpoint because the provider must reach the data plane
on create and every read. Access is Microsoft Entra ID only (no shared keys or
anonymous access); apps should use the private endpoint. TLS 1.2, blob versioning
and 7 days of soft delete are fixed. Its name is `st` plus a hash of subscription,
namespace and name, shown in `status.accountName`. Grant data access with Azure RBAC, for example
**Storage Blob Data Contributor** on `status.resourceID`.

Because of that public endpoint, Azure Landing Zones policies that deny public
network access (for example on the corp management group) will block Bucket.
If the cluster resolves `privatelink.blob.core.windows.net` privately, it also
needs a network route to the private endpoint for provider data-plane calls.

All resources use the Space's ProviderConfig. The composition does not create
private DNS records; it relies on the Azure Landing Zones DeployIfNotExists policy
for `privatelink.blob.core.windows.net`. Without that policy, configure DNS yourself.
The Network and its Space must have their subnet and identity outputs available.
Missing dependencies or empty status outputs fail reconciliation without
dropping existing composed resources.

Status publishes `accountName`, `resourceID` and `blobEndpoint`.

Deleting a Bucket deletes the storage account and all its data. Removing a
container from the list deletes that container. A Usage keeps the Network, and
through it the Space, until Bucket cleanup completes.
See the [example](../projects/services/examples/bucket.yaml).

## SecretStore

A [SecretStore](../projects/services/apis/secretstore/definition.yaml) is a
private Key Vault. It selects a Network by name in the same namespace and uses
that Network's Space and subnet. It owns a resource group named
`secretstore-<metadata.name>`, a vault and a vault private endpoint in the
Network subnet.

Inputs are `network` (immutable) and optional `tags`. Platform-owned tags take
precedence over user tags with matching keys. Tag keys must be lowercase.
Region and tenant come from EnvironmentConfig.

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

Status publishes `vaultName`, `resourceID`, `vaultURI` and `privateEndpointID`.

Deleting a SecretStore deletes the endpoint, vault and resource group. Purge
protection keeps the vault and its contents soft-deleted and recoverable for 90
days, and its name stays reserved; recovery does not restore role assignments.
A Usage keeps the Network, and through it the Space, until cleanup completes.
See the [example](../projects/services/examples/secretstore.yaml).

## App

An [App](../projects/services/apis/app/definition.yaml) runs one public container
image in its own Container Apps Consumption environment. It selects a Network
in the same namespace, uses that Network's Space ProviderConfig, and owns a
resource group named `app-<metadata.name>`, the environment and the app.

Inputs are `network`, `image`, `targetPort` (default 8080), `exposure` (default
private) and optional `tags`. Network and exposure are immutable. Use an explicit
image version tag other than `latest` or a SHA-256 digest; digests are preferred
because tags can move. Platform-owned tags override matching user tags.
Tag keys must be lowercase.
Azure app names are `ca` plus a hash of subscription, namespace and XR name.

Private exposure disables environment public access and creates a private
endpoint in the selected Network subnet. Public exposure enables internet
ingress and creates no private endpoint; it is independent of Space's governance
exposure. App-level ingress is external in both modes: it publishes the app at
the environment boundary, not necessarily on the internet. HTTPS-only ingress,
single revisions, 0.25 vCPU / 0.5Gi, 1-3 replicas and HTTP scaling at 50 concurrent
requests are fixed. The application must authenticate its callers.

Every App has a system-assigned identity, published in `status.principalID`.
Grant data-access roles externally; the API creates no role assignments.
Private endpoints provide **inbound access only**. There is no VNet injection,
so this App cannot yet reach private Bucket or SecretStore endpoints.
There are no environment variables, secrets, private registry credentials or
custom domains.

Private DNS must be supplied by platform policy or setup for
`privatelink.<region>.azurecontainerapps.io`. No persisted log sink is configured;
only live log streaming is available until the platform supplies logging.
Dedicated environments and private endpoints carry additional costs.
Deleting an App deletes its infrastructure and identity. Sequenced v2 Usages
keep the environment and selected Network until dependent cleanup completes.
Missing dependencies or required outputs fail reconciliation without dropping
existing composed resources.

Try the [private](../projects/services/examples/app.yaml) or
[public](../projects/services/examples/app-public.yaml) example. Status publishes
the app and environment IDs, domain, FQDN, HTTPS URL, identity principal and
private endpoint ID/IP when present.

## LandingZone

A [LandingZone](../projects/stacks/apis/landingzone/definition.yaml) bundles one
Space, Network, Bucket and SecretStore. All four child XRs have the LandingZone's
name and namespace; do not create standalone XRs of those kinds with the same
name there. The stack only composes platform APIs, never Azure resources.

Inputs are `displayName`, `exposure` and these optional fields:

- `networkSize`: `small`, `medium` (default) or `large`.
- `containers`: 1-20 named blob containers. Omit it for one named `default`;
  an empty list is invalid. Removing a container deletes its data.
- `geoRedundant`: false (default) uses ZRS; true uses GZRS.
- `tags`: up to 40 entries, with keys up to 128 characters and values up to 256.
  Keys must be lowercase. Tags go to all four children; each child applies
  platform-owned tag precedence.

Exposure, networkSize and geoRedundant are immutable. Exposure selects corp
(`private`) or online (`public`) subscription governance; it does not change
Bucket or SecretStore network access. Region, identities and other platform
settings remain in EnvironmentConfig.

Space becomes ready first, then Network, then Bucket and SecretStore in
parallel. LandingZone is ready only when all four children are ready and have
published the required outputs. Status exposes `spaceName`, `networkName`,
`subscriptionID`, `subnetID`, `accountName`, `blobEndpoint`, `vaultName` and
`vaultURI`. Additional services can select the owned Network by that name.

Install the foundation and services APIs and configure the platform identity,
EnvironmentConfig and private DNS before use. Bucket still requires provider
data-plane reachability and has a public endpoint; SecretStore is private.
The stack adds neither data-access grants nor DNS records. An App can select
this Network, but its current private-outbound limitation still applies.

Try the [private](../projects/stacks/examples/landingzone-private.yaml) example
with defaults or the [public](../projects/stacks/examples/landingzone-public.yaml)
example with custom containers and geo redundancy.

Delete with foreground cascading deletion so sequenced v2 Usages preserve
the Network and Space identity until service cleanup completes:

```shell
kubectl delete landingzone development -n team-a --cascade=foreground
```

Deletion **deletes the Bucket and its data** and is meant to cancel the
subscription (not yet verified against Azure).
SecretStore's purge-protected vault stays recoverable for 90 days. Management
group associations and resource-provider registrations remain for the
subscription's lifetime, as documented by Space. See
[Clean up](deployment.md#12-clean-up) for how to confirm deletion finished.
