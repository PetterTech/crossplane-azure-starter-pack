# Walkthrough

This runbook is ordered for a starter-pack walkthrough. It can be used for local learning, team onboarding, or demo sessions.

## Narrative goals

- Developers use simple cloud-agnostic claims.
- Claims bind to public platform composites (`XLandingZone`, `XNetwork`, `XStorage`).
- Platform engineers own Azure implementation details.
- `LandingZone` establishes scope for child products.
- `Network` references `LandingZone` without repeating information.
- Internal Azure compositions choose `corp` vs `online` behavior.
- `Storage` proves the same pattern for managed resources.

## 1) Apply admin prerequisites (platform engineer)

```bash
kubectl apply -f examples/platform-admin/platform-config.yaml
kubectl apply -f examples/platform-admin/provider-config.yaml
```

## 2) Apply XRDs

```bash
kubectl apply -f platform/apis/landingzone/xrd.yaml
kubectl apply -f platform/apis/network/xrd.yaml
kubectl apply -f platform/apis/storage/xrd.yaml
kubectl apply -f platform/apis/azure/xazurelanding-zone/xrd.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/xrd.yaml
kubectl apply -f platform/apis/azure/xazurestorage-account/xrd.yaml
```

## 3) Apply compositions

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

## 4) Apply developer claims in order

```bash
kubectl apply -f examples/claims/01-landing-zone-corp.yaml
kubectl apply -f examples/claims/02-network-corp.yaml
kubectl apply -f examples/claims/05-storage.yaml
```

Say:

- The developer API is tiny: app intent, environment, product size/access.
- `Network` only needs a `landingZoneRef` and `size`; it does not repeat landing zone type.
- `Storage` follows the same reference pattern and maps to Azure resources internally.

## 5) Inspect public claims

```bash
kubectl get landingzones.platform.example.org
kubectl get networks.platform.example.org
kubectl get storages.platform.example.org
```

## 6) Inspect public composites

```bash
kubectl get xlandingzones.platform.example.org
kubectl get xnetworks.platform.example.org
kubectl get xstorages.platform.example.org
```

## 7) Inspect internal XRs

```bash
kubectl get xazurelandingzones.azure.platform.example.org
kubectl get xazurevirtualnetworks.azure.platform.example.org
kubectl get xazurestorageaccounts.azure.platform.example.org
```

Say:

- Public products are for app teams.
- Public composites are the platform-owned contract behind claims.
- Internal Azure XRs are platform-owned implementation contracts.
- This split keeps the public API cloud-agnostic.

## 8) Inspect managed resources

```bash
kubectl get virtualnetworks.virtualnetwork.network.azure.m.upbound.io
kubectl get subnets.subnet.network.azure.m.upbound.io
kubectl get securitygroups.network.azure.m.upbound.io
kubectl get accounts.storage.azure.m.upbound.io
kubectl get privateendpoints.network.azure.m.upbound.io
```

Say:

- You can now trace one flow from claim to public composite to Azure managed resources.
- `Network` profile behavior is selected internally (`corp` or `online`) through composition labels.

## 9) Clean up claims

```bash
kubectl delete -f examples/claims/05-storage.yaml
kubectl delete -f examples/claims/02-network-corp.yaml
kubectl delete -f examples/claims/01-landing-zone-corp.yaml
```

The `Network` flow intentionally includes a small Go templating decision step that reads the referenced `LandingZone` and selects the correct internal Azure network composition (`corp` or `online`).
