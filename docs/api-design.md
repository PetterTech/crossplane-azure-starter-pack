# API Design

## Public API group

Public APIs live in platform.example.org/v1alpha1.

They describe product intent and remain cloud-agnostic.

Public claim/composite mappings:

- LandingZone claim -> XLandingZone composite
- Network claim -> XNetwork composite
- Storage claim -> XStorage composite

## Internal API group

Internal Azure APIs live in azure.platform.example.org/v1alpha1.

They hold Azure-specific implementation details owned by platform engineers.

## Rules used in this starter pack

- LandingZone establishes scope for child products.
- Developers reference a LandingZone by name.
- Public compositions target platform composite kinds (XLandingZone, XNetwork, XStorage).
- Public Network does not accept CIDR or address space.
- Public Network does not repeat landing-zone type or profile information.
- Public Storage remains cloud-agnostic.
- ProviderConfig naming convention matches the LandingZone name.
- Internal XAzureVirtualNetwork compositions are selected by a derived networkProfile label.
- LandingZone `type: corp` maps to internal `networkProfile: corp`.
- LandingZone `type: online` maps to internal `networkProfile: online`.
- XAzureVirtualNetwork uses `compositionSelector.matchLabels.platform.example.org/network-profile` to select:
	- `xazurevirtualnetwork-corp` for `corp`
	- `xazurevirtualnetwork-online` for `online`
- Internal Azure compositions carry `corp` vs `online` behavior.

This repository currently implements the Azure branch for these public APIs. Additional cloud branches can be added without changing the public claim shapes.
