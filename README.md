# Crossplane Azure Starter Pack

This repository is a conference-demo starter pack for showing how platform teams can expose simple, cloud-agnostic products while keeping Azure implementation details internal.

It focuses on:

- clear story and demo flow
- clean public product APIs for developers
- internal Azure APIs and compositions for platform engineers
- small, readable examples that show the layering pattern

## Demo story in one minute

1. Developers request products using simple, cloud-agnostic claims.
2. Claims bind to public platform composites (`XLandingZone`, `XNetwork`, `XStorage`).
3. `LandingZone` establishes scope and shared defaults for later products.
4. `Network` references `LandingZone` and does not repeat environment/profile details.
5. Public platform composites create internal Azure composites.
6. Internal Azure compositions choose `corp` or `online` behavior.
7. `Storage` follows the same pattern, proving this scales beyond networking.

## Public platform APIs (developer-facing)

The developer-facing API group is `platform.pettertech.com/v1alpha1`.

Initial products:

- Claim kinds: `LandingZone`, `Network`, `Storage`
- Composite kinds: `XLandingZone`, `XNetwork`, `XStorage`

These APIs describe intent and intentionally hide Azure-specific details such as subscription IDs, resource group names, CIDR strategy, and provider config wiring.

## Internal Azure APIs (platform-owned)

The internal implementation API group is `azure.platform.pettertech.com/v1alpha1`.

Initial internal products:

- `XAzureLandingZone`
- `XAzureVirtualNetwork`
- `XAzureStorageAccount`

These APIs contain Azure implementation concerns behind the public API boundary.

## Layered model

```text
Developer-facing claim
  -> public platform composite resource
  -> public composition
  -> internal Azure composite resource
  -> internal Azure composition
  -> Azure managed resources
```

`Network` includes a placeholder Go templating step because it needs to read its referenced `LandingZone` and derive an internal network profile.

## Conference demo flow

The manifests under `examples/claims/` are the developer-facing entry point.

### 1) Apply admin prerequisites (platform engineer step)

```bash
kubectl apply -f examples/platform-admin/platform-config.yaml
kubectl apply -f examples/platform-admin/provider-config.yaml
```

### 2) Apply XRDs

```bash
kubectl apply -f platform/apis/landingzone/xrd.yaml
kubectl apply -f platform/apis/network/xrd.yaml
kubectl apply -f platform/apis/storage/xrd.yaml
kubectl apply -f platform/apis/azure/xazurelanding-zone/xrd.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/xrd.yaml
kubectl apply -f platform/apis/azure/xazurestorage-account/xrd.yaml
```

### 3) Apply compositions

```bash
kubectl apply -f platform/functions/function-go-templating.yaml
kubectl apply -f platform/apis/landingzone/composition.yaml
kubectl apply -f platform/apis/network/composition.yaml
kubectl apply -f platform/apis/storage/composition.yaml
kubectl apply -f platform/apis/azure/xazurelanding-zone/composition.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/composition-corp.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/composition-online.yaml
kubectl apply -f platform/apis/azure/xazurestorage-account/composition.yaml
```

### 4) Apply developer claims in dependency order

```bash
kubectl apply -f examples/claims/01-landing-zone-corp.yaml
kubectl apply -f examples/claims/02-network-corp.yaml
kubectl apply -f examples/claims/05-storage.yaml
```

Talk track:

- `LandingZone` first: establishes product scope and shared identity/provider convention.
- `Network` next: references `LandingZone` by name and inherits profile context.
- `Storage` last: proves the same model works for managed resource products too.

### 5) Inspect public claims

```bash
kubectl get landingzones.platform.pettertech.com
kubectl get networks.platform.pettertech.com
kubectl get storages.platform.pettertech.com
```

### 6) Inspect public composites

```bash
kubectl get xlandingzones.platform.pettertech.com
kubectl get xnetworks.platform.pettertech.com
kubectl get xstorages.platform.pettertech.com
```

### 7) Inspect internal Azure XRs (platform-owned layer)

```bash
kubectl get xazurelandingzones.azure.platform.pettertech.com
kubectl get xazurevirtualnetworks.azure.platform.pettertech.com
kubectl get xazurestorageaccounts.azure.platform.pettertech.com
```

### 8) Inspect resulting Azure managed resources

```bash
kubectl get virtualnetworks.virtualnetwork.network.azure.m.upbound.io
kubectl get subnets.subnet.network.azure.m.upbound.io
kubectl get securitygroups.network.azure.m.upbound.io
kubectl get accounts.storage.azure.m.upbound.io
kubectl get privateendpoints.network.azure.m.upbound.io
```

### 9) Clean up demo claims

```bash
kubectl delete -f examples/claims/05-storage.yaml
kubectl delete -f examples/claims/02-network-corp.yaml
kubectl delete -f examples/claims/01-landing-zone-corp.yaml
```

This repository is intentionally educational. Where exact Upjet Azure resource field mappings still need validation, comments and TODOs are explicit rather than implying production completeness.
