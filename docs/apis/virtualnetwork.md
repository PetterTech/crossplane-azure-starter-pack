# VirtualNetwork

`VirtualNetwork` (`platform.a5n.io/v1alpha1`, namespaced) creates, in the namespace's Subscription:

- a virtual network whose address space the platform IPAM pool allocates (`size`: small, medium or large, mapped to 128, 256 or 512 addresses);
- one subnet over that address space (`createSubnet`, default true);
- a network security group that denies inbound traffic from the Internet unless a rule in `networkSecurityGroup.allowInbound` allows it, associated with the subnet (`networkSecurityGroup.enabled`, default true);
- a connection to the platform's virtual hub (`peerToHub`, default true) when the EnvironmentConfig has `hubVirtualHubId`.

There is no ManagementLock. Everything is tagged with `a5n-namespace`, `a5n-owner-xr` and `a5n-xr-uid`, plus `costCenter`, `owner` and `environment` from `spec.parameters.tags`.

## Example

See `projects/foundation/examples/virtualnetwork/virtualnetwork.yaml`.

## Which Subscription

The shared resolver (`projects/foundation/apis/_shared/resolver.md`) uses `spec.subscription`, or else the only Ready `Subscription` in the namespace, and pins it in `status`. All resources use the `ProviderConfig` named after it. Location and resource group come from the EnvironmentConfig (`spec.parameters.location` and `resourceGroupName` override them once) and are pinned too.

## Pipeline

`environment-configs` -> `function-kro` (the whole graph; function-kro replaces earlier status, so the resolver runs after it) -> `resolve-subscription` (shared go-templating) -> `function-auto-ready`. There is no patch-and-transform step: the resources depend on each other's observed state, and three of them are optional on a boolean.

On the first reconcile only the pin is written. From the second, the VNet and the NSG are created; the subnet and the hub connection follow once the VNet reports its address space, and the association once subnet and NSG exist.

## Environment keys

| Key | Use |
| --- | --- |
| `location`, `resourceGroupName` | where the resources go (pinned) |
| `ipamPoolId` | required; the pool the VNet allocates from (pinned) |
| `hubVirtualHubId` | optional; pinned with the rest of `status.environment` when the virtual network is first composed. Without it `peerToHub` creates nothing and `EnvironmentValid` is `False` with reason `HubNotConfigured`. A hub added to the environment later does not reach existing virtual networks (create a new one, or a future migration); a hub removed later does not remove the connection. `EnvironmentDrift` reports both, and changes of `ipamPoolId`. |
| `allowedLocations` | optional, comma separated; checked when the location is first pinned |

## Status

`vnetName`, `resourceId`, `addressSpace`, `subnetId`, `networkSecurityGroupId`, and the pins (`subscription`, `subscriptionUid`, `subscriptionId`, `environment`).

## Allowed inbound sources

`sourceAddressPrefix` is the service tag `VirtualNetwork` or a private (RFC 1918) range inside 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16 (octets 0-255, no leading zeros). Everything else, including 0.0.0.0/x, split-internet ranges, public ranges, `Internet` and `*`, is rejected by CEL, so no rule (SSH 22, RDP 3389 included) can open the subnet to the Internet.

`sourceAddressPrefix: VirtualNetwork` is only as isolated as E12 makes it: it includes peered networks and the platform's AllowVnetInBound path, so with hub peering and no route-table isolation other tenants' VNets can match it.

## Not proven live

- function-kro reading the XR through its own `externalRef`, and the resolver's `status` merging with kro's, are proven on kind by the pins persisting (reviewer run); the composed graph itself is only proven under `crossplane render`.
- go-templating `ExtraResources` with a templated namespace is used by the Subscription/VirtualNetwork resolver; whether the function restricts the requested namespace live is not confirmed.
- A Fatal result keeps the composed resources (no deletes) under render; this is not confirmed on a live Crossplane.

## Unverified until the first sandbox deploy

See "Unverified until the first sandbox deploy" in `docs/identity-bootstrap.md` for the list of RBAC actions, fail-closed 403, E12 isolation, CEL acceptance and live ExtraResources/Fatal behaviour that remain unproven. The Crossplane RBAC install prerequisite is in the same file.

## Protection and platform decisions

- `createSubnet: false` and `networkSecurityGroup.enabled: false` give no NSG protection. This is a platform decision, and the XR shows a tenant-visible warning.
- A hub added to the environment after the virtual network was first composed does not reach it; recreate the virtual network. A hub removed later keeps the pinned connection. `EnvironmentDrift` reports both.
- `allowedLocations` is checked at the first pin only.
- Paths the resolver cannot resolve are Fatal and visible in the `Synced` condition message.

## Prerequisite: hub and IPAM rights (E11)

The hub connection and the IPAM allocation act on resources outside the tenant Subscription. The per-subscription identity has Contributor on its own subscription only (E1), so both calls return 403 and the VirtualNetwork fails closed until two narrow custom roles are granted:

- a hub-connection role (`Microsoft.Network/virtualHubs/hubVirtualNetworkConnections/{read,write,delete}`) at hub scope;
- a pool-association role (`Microsoft.Network/ipamPools/associateResourcesToPool/action`) at pool scope.

The identity-admin gate grants them to each per-subscription UAMI; no composition does. They are not Network Contributor and not subscription-wide (see `docs/identity-bootstrap.md`). E11 is owned by Petter and is open to veto.

Blast radius: every per-subscription UAMI trusts the shared-tier ServiceAccount, so any shared-tier pod token can alter or delete any tenant's hub connection and consume pool space. The number of VNets per namespace is unbounded unless you apply a ResourceQuota on VirtualNetwork count, so IPAM exhaustion is possible: set the quota and monitor pool size.

## Hub routing isolation (E12)

Hub peering may let tenant VNets reach each other. Accepted as a documented risk for the sandbox only. A hub route table and association that isolates tenant VNets must be decided at sandbox time and is mandatory before the first non-sandbox deployment.

## Threat model

- The resolver is the trust boundary: it takes the subscription name from the XR (E4) and verifies the Subscription's UID and subscriptionId.
- The subscription, location, resource group, `hubVirtualHubId` and `ipamPoolId` are pinned in `status` and write-once (CEL); later environment changes do not re-aim existing virtual networks.
- Fail-closed: an unresolved subscription, environment or missing right stops composition (Fatal) rather than falling back to another subscription or an unpinned value.
- Inbound sources are limited by CEL (see above); no rule can open the subnet to the Internet.

## Tests

`projects/foundation/tests/virtualnetwork/run.sh` renders every reconcile stage with `crossplane render`, including the fail-closed and hub/IPAM-change cases. `kind-cel.sh` applies the XRD to a throwaway kind cluster and tests the status write-once rules and the source-prefix rule.
