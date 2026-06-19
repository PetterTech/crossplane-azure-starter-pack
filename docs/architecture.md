# Architecture

This starter pack demonstrates a layered Crossplane architecture for exposing simple platform products while keeping Azure implementation details internal.

## Layers

1. Developer-facing claims in `platform.pettertech.com/v1alpha1`
2. Public platform composites in the same API group
3. Public platform compositions
4. Small selector or decision logic where needed
5. Internal Azure composites in `azure.platform.pettertech.com/v1alpha1`
6. Azure-specific internal compositions
7. Azure managed resources later

## Why the split matters

The public claim API is for developers and application teams. It describes outcomes, not Azure mechanics.

The public composite API is the platform-owned contract behind those claims.

The internal Azure API is for platform engineers. It carries implementation-specific fields and provider wiring that the public API should not expose.

## Product flow used in the demo

`LandingZone` establishes scope for an application environment and the provider config naming convention used by child products.

`Network` references `LandingZone` and derives internal profile behavior. Developers do not provide CIDR ranges, routing inputs, or profile duplication.

`Storage` references `LandingZone` and maps to Azure managed resources, proving the pattern is reusable beyond networking.

## Composition strategy

- Use declarative patching by default.
- Use Go templating only where small decision logic is required (currently `Network` profile selection).
- Keep placeholders explicit where Azure details still need validation.
