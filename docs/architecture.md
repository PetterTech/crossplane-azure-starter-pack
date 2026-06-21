# Architecture

This repository follows a layered Crossplane model that keeps developer APIs cloud-agnostic and places Azure implementation details behind internal contracts.

## Layered model

```text
Developer-facing claim
	-> public platform composite resource
	-> public platform composition
	-> internal Azure composite resource
	-> internal Azure composition
	-> Azure managed resources
```

## Layers in this starter pack

1. Developer-facing claims and public composites in platform.example.org/v1alpha1.
2. Public platform compositions that translate intent into internal implementation inputs.
3. Internal Azure composites in azure.platform.example.org/v1alpha1.
4. Azure-specific compositions and managed resources.

## Why this split matters

- App teams work with product intent, not cloud mechanics.
- Platform engineers can iterate on Azure implementation details without breaking public APIs.
- The same public API shape can support future AWS or GCP internal branches.

## Azure branch today

Example flow in this repository:

```text
Network claim
	-> XNetwork
	-> XAzureVirtualNetwork
	-> Azure VNet resources
```

Network is cloud-agnostic. This starter pack currently provides the Azure implementation.

## Composition approach

- Prefer patch-and-transform compositions.
- Use Go templating only where patch-and-transform is insufficient.
- Keep placeholders and TODOs explicit where provider schema validation or production hardening is still pending.
