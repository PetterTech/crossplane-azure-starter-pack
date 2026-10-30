# LandingZone

`LandingZone` (`platform.a5n.io/v1alpha1`, namespaced) vends a new Azure subscription for a workload and, in it, the building blocks you ask for. A landing zone with no fields creates only the subscription and its resource group.

**Read this first.** Tenants create landing zones without an approval step (E3, accepted risk). Deleting a landing zone never cancels or deletes the subscription or its resource group; the platform team cancels the subscription by hand. See `docs/tenant-controls.md` ("Landing zone baseline") for the mandatory controls.

## What it creates

- a `Subscription` XR (`docs/apis/subscription.md`) named like the landing zone, or like `spec.subscription`, in the same namespace; it is composed with patch-and-transform and controlled by the landing zone;
- one `ResourceGroup` in the new subscription, `rg-<name>` unless `parameters.resourceGroupName` is set (D10). It is never deleted (no `Delete` in `managementPolicies`) and never locked;
- optionally a `VirtualNetwork` XR (`parameters.network`) in the new subscription, with one subnet and optional peering to the hub; or, instead, the lookup of an existing `VirtualNetwork` named in `spec.virtualNetwork`;
- optionally a `StorageAccount` XR (`parameters.storageAccount`) and a `KeyVault` XR (`parameters.keyVault`). They share the landing zone's name (D9), are always `networking: private`, and their private endpoints use the landing zone's subnet through `parameters.privateEndpointSubnetId`.

Everything is tagged with `a5n-namespace`, `a5n-owner-xr` and `a5n-xr-uid`, plus `costCenter`, `owner` and `environment` from `spec.parameters.tags`. Children get `spec.subscription` set to the landing zone's subscription.

## Example

See `projects/landingzone/examples/landingzone/landingzone.yaml`.

## Rules

| Rule | Where |
| --- | --- |
| `deletionPolicy: Delete` only with `workload: DevTest` (E16); Production is Orphan only | CEL |
| `spec.virtualNetwork` and `parameters.network` are mutually exclusive | CEL |
| `storageAccount` and `keyVault` need a network (created or referenced) | CEL |
| `subscription`, `virtualNetwork`, `workload`, `location`, `resourceGroupName` are fixed once set; `status` pins are write-once | CEL |
| at most 20 containers, 10 tags; tag keys `costCenter`, `owner`, `environment` only | CEL |
| names: not `default`, no `platform-` prefix, at most 30 characters | CEL |

## Subscription, name and refusal (D12)

The shared resolver (`projects/foundation/apis/_shared/resolver.md`, section LandingZone) looks for the Subscription named by `spec.subscription`, or else after the landing zone. If it exists, it must have the landing zone as controller (ownerReference with its uid). A Subscription of that name that anyone else controls, or nobody controls, is refused with a Fatal `SubscriptionNotControlled`: the landing zone never adopts a foreign Subscription. Crossplane's own controller-reference check on apply is a second layer (unverified, below).

While the Subscription does not exist or is not Ready, `SubscriptionResolved=False` (`SubscriptionPending`) and nothing else is composed; this is a wait, not a failure. When it is Ready the resolver pins `status.subscription`, `subscriptionUid`, `subscriptionId`, `providerConfigName` and `status.environment` (location and resource group). A pinned landing zone whose Subscription disappears, is recreated or no longer matches fails with `SubscriptionChanged`, `SubscriptionNotReady` or `SubscriptionMismatch`.

## Network

With `parameters.network` the `VirtualNetwork` XR is composed once the resource group is Ready, in the new subscription. With `spec.virtualNetwork` the named `VirtualNetwork` in the same namespace is used. In both cases the resolver waits until it has a subnet (`VirtualNetworkResolved=False`: `VirtualNetworkNotFound`, `VirtualNetworkNotReady`), then pins `status.network` once. A virtual network or subnet outside the landing zone's own subscription is Fatal (`VirtualNetworkNotInSubscription`). The storage account and key vault are composed only after the pin exists. The platform's shared private endpoint subnet is never used by a landing zone.

## Deletion

`deletionPolicy` (default `Orphan`) applies to the storage account and key vault only: `Orphan` leaves them in Azure with their data, `Delete` (DevTest only) deletes them (a key vault stays soft-deleted with purge protection). It never applies to the subscription or the resource group. A new landing zone of the same name adopts what was orphaned. Removing `storageAccount` or `keyVault` from the spec stops composing that XR; the child's own `deletionPolicy` decides what happens in Azure.

## Pipeline

`environment-configs` -> `function-kro` (resource group, network, storage account, key vault; kro reads the pins through an `externalRef` to the XR itself) -> `resolve-subscription` (shared resolver, inlined copy) -> `subscription` (patch-and-transform) -> `auto-ready`. Blocks are on while their parameter is present and off when it is absent. The kro gates use only spec and write-once pins; everything that must fail closed is a Fatal of the resolver.

## Status

`subscription`, `subscriptionUid`, `subscriptionId`, `providerConfigName`, `environment{location,resourceGroupName}`, `network{virtualNetwork,subnetId}`, and the outputs `storageAccountName`, `blobEndpoint`, `keyVaultName`, `keyVaultUri`. Conditions: `SubscriptionResolved`, `EnvironmentValid`, `EnvironmentDrift`, `VirtualNetworkResolved` (only with a network), `Ready`, `Synced`.

Known behaviour: `Ready` can show `True` for about one reconcile after the Subscription (or the network pin) appears and before the next block is composed, because auto-ready looks only at resources that exist. Wait for the status outputs, not only for `Ready`.

## Threat model

- The resolver is the trust boundary: Subscription controller check, uid and subscriptionId pins, subscription of the network and subnet, and the location allow list. Tenants cannot choose billing scope, management group, tenant, hub or default region (M1).
- Self-service without approval (E3): unbounded subscription creation is limited only by the quota and Azure limits in the baseline (M5, M6).
- The vending identity is shared with every per-subscription identity (E2, E9). No ManagementLock is composed (standing constraint), so the resource group has no lock.
- Children are always private, and a tenant-set `privateEndpointSubnetId` of a child must be in that resource's own subscription (the resolver refuses another one). There is no DNS zone group: create `privatelink.blob.core.windows.net` and `privatelink.vaultcore.azure.net` (hub DNS or policy); until then the private endpoints are unreachable by name. Subnet join in the vended subscription is covered by Contributor (D13, E13), unverified.
- Tags: the `a5n-*` tags of the children carry each child's own identity (its namespace, owner XR and uid), which differs from the resource group's tags.
- Fail closed: unresolved subscription, environment, location, network or subnet are Fatal or a wait; nothing is composed.

## Unverified until the first sandbox deploy

- The `Subscription` XR composed with patch-and-transform from a namespaced landing zone, controlled by it, and Crossplane's refusal (server-side apply conflict) for a foreign Subscription of the same name (D9, D12). Only the resolver refusal is tested.
- Crossplane's RBAC manager granting the XR kinds of the foundation and services Configurations on first install (D9).
- Cross-subscription subnet join: private endpoints of the storage account and key vault in the new subscription's subnet, covered by Contributor (D13, E13).
- Peering to the hub (`peerToHub`) from a new subscription.
- The format of `resourceGroup.status.atProvider.location` that the children use as their location. If it differs from the location the child accepts, the child fails closed (non-compliant but safe: nothing is created in a wrong place).
- D13: subnet join in the new subscription's subnet under Contributor.
- The Subscription stays in Azure (Orphan) when a landing zone is deleted.
- The Ready flicker described above.
- A Subscription cancelled by hand in Azure (the landing zone only sees the Subscription XR).
- Live behaviour of `Orphan` and `Delete` against a real provider (only the policy lists were verified, on kind).

## Tests

`projects/landingzone/tests/landingzone/run.sh` renders each reconcile stage with `crossplane render`, validates the composed ResourceGroup against the provider v2.8.0 CRDs and the child XRs against their XRDs, and covers the variants (Delete/DevTest, blocks on and off, `spec.virtualNetwork`, a custom subscription name), the Fatal cases and the waits. `kind-cel.sh` runs the XRD's CEL on a throwaway kind cluster. `live.sh` installs Crossplane 2.4.3 and the pinned functions on one, with the ResourceGroup provider CRD and stub CRDs for the XRs (status patched by hand), and checks the pins, the controller reference, a function-kro restart, `deletionPolicy` flips, the foreign-Subscription refusal and the network-in-another-subscription refusal. Set `CLUSTER` to choose the kind cluster name.
