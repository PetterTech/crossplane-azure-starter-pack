# API Design

## Public API group

Public APIs live in `platform.pettertech.com/v1alpha1`.

They describe product intent and remain cloud-agnostic.

Public claim/composite mappings:

- `LandingZone` claim -> `XLandingZone` composite
- `Network` claim -> `XNetwork` composite
- `Storage` claim -> `XStorage` composite

## Internal API group

Internal Azure APIs live in `azure.platform.pettertech.com/v1alpha1`.

They hold Azure-specific implementation details owned by platform engineers.

## Rules used in this starter pack

- `LandingZone` establishes scope for child products.
- Developers reference a `LandingZone` by name.
- Public compositions target platform composite kinds (`XLandingZone`, `XNetwork`, `XStorage`).
- Public `Network` does not accept CIDR or address space.
- Public `Network` does not repeat landing-zone type/profile information.
- Public `Storage` remains cloud-agnostic.
- The provider config name convention matches the `LandingZone` name.
- Internal `XAzureVirtualNetwork` compositions are selected by a derived `networkProfile` label.
- Internal Azure compositions carry `corp` vs `online` behavior.
