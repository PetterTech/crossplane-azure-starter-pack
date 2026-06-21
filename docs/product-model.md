# Product Model

The starter pack begins with three public products and three internal Azure implementation products.

## Public products

Each public product has a developer-facing claim kind and a platform-owned composite kind:

- LandingZone claim -> XLandingZone composite
- Network claim -> XNetwork composite
- Storage claim -> XStorage composite

### LandingZone

Represents the main platform scope for an application environment.
Child products reference it instead of repeating shared context.

Developer inputs:

- `application`
- `environment`
- `type`
- `owner`
- optional `tags`

### Network

Represents network intent inside a landing zone.

Developer inputs:

- `landingZoneRef.name`
- `size`
- optional `tags`

The public API intentionally does not ask for CIDR blocks or address space.
The platform derives profile-specific behavior (corp vs online) from the referenced LandingZone.

### Storage

Represents a cloud-agnostic storage product bound to a landing zone.

Developer inputs:

- `landingZoneRef.name`
- `geo-redundant`
- `access`
- optional `tags`

This product demonstrates the same layered pattern for managed resources, not only networking.

Public APIs stay cloud-agnostic. This repository currently maps them to Azure internal products.

## Internal Azure products

### XAzureLandingZone

Carries Azure-specific concerns such as subscription vending, identity, role assignment, and landing-zone-specific provider configuration.

### XAzureVirtualNetwork

Carries Azure-specific network behavior and selects either the `corp` or `online` composition variant.

### XAzureStorageAccount

Carries Azure-specific storage account behavior and related managed resources for starter-pack scope.
