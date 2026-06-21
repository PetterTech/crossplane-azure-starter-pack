# Decisions

## Initial decisions

1. Public APIs are cloud-agnostic and developer-facing.
2. Azure-specific behavior lives behind internal composite resources.
3. Declarative patching is the default composition approach.
4. Go templating is reserved for decision layers.
5. Readability and teaching value are prioritized over production completeness.
6. Internal `XAzureVirtualNetwork` compositions use Upjet Azure managed resources:
	- `VirtualNetwork` (`virtualnetwork.network.azure.m.upbound.io/v1beta1`)
	- `Subnet` (`subnet.network.azure.m.upbound.io/v1beta1`)
	- `SecurityGroup` (`network.azure.m.upbound.io/v1beta1`, corp only)
7. Keep corp and online network implementations as separate compositions.
8. Do not add advanced routing or private endpoint complexity in the initial network implementation.
9. Corp virtual network and subnet consume Azure native IPAM pool ID from EnvironmentConfig `platform-defaults` and derive `numberOfIpAddresses` from size.
10. Online virtual network is isolated and uses static size-based CIDRs without Azure Firewall DNS dependency or IPAM lookup.
11. Storage follows the same public-to-internal layering model and demonstrates managed resource mapping.

## Deferred decisions

1. Exact Upjet Azure managed resource schemas still need validation.
2. Landing zone subscription vending, identity, and role assignment remain placeholder-only.
3. Storage implementation is intentionally minimal for starter-pack scope and still needs production hardening.
4. Azure native IPAM field mapping in Upjet for virtual network/subnet address assignment still needs final validation.
