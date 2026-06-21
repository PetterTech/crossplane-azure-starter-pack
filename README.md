# Crossplane Azure Starter Pack

This repository is a reusable starter pack for building developer-friendly Azure platform APIs with Crossplane. It shows how a platform team can expose simple claims such as LandingZone, Network, and Storage while hiding Azure-specific implementation details behind internal compositions.

It is designed for platform engineers who want to learn the pattern, adapt it to their own environment, and contribute improvements back to the project.

## What this solves

- A clean public API contract for application teams.
- A layered composition model that keeps Azure details internal.
- A practical reference implementation for Azure using Crossplane.
- Small examples that are easy to run, inspect, and modify.

## What this does not solve yet

- Full production hardening.
- Complete enterprise governance integration.
- Turnkey CI/CD, GitOps, or policy framework setup.

See docs/non-goals.md for details.

## Public API first

Public APIs are cloud-agnostic and developer-facing.

- API group: platform.example.org/v1alpha1
- Claim kinds: LandingZone, Network, Storage
- Composite kinds: XLandingZone, XNetwork, XStorage

These APIs describe intent and intentionally do not expose Azure implementation mechanics such as subscription IDs, resource group names, provider wiring, or CIDR strategy.

## Azure implementation layer

This starter pack currently implements the Azure branch behind the public API contract.

- Internal API group: azure.platform.example.org/v1alpha1
- Internal kinds: XAzureLandingZone, XAzureVirtualNetwork, XAzureStorageAccount

Layered model:

```text
Developer-facing claim
  -> public platform composite resource
  -> public platform composition
  -> internal Azure composite resource
  -> internal Azure composition
  -> Azure managed resources
```

Example:

```text
Network claim
  -> XNetwork
  -> XAzureVirtualNetwork
  -> Azure VNet resources
```

Network is cloud-agnostic. This starter pack implements Network using Azure. A future implementation can add AWS or GCP internal resources without changing the public Network API.

## Prerequisites

This starter pack assumes you have access to a Kubernetes cluster and `kubectl` context with cluster-admin rights.

Install Crossplane:

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace
```

Install the required Azure providers and function packages:

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-family-azure
spec:
  package: xpkg.upbound.io/upbound/provider-family-azure:v1
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-azure-network
spec:
  package: xpkg.upbound.io/upbound/provider-azure-network:v1
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-azure-storage
spec:
  package: xpkg.upbound.io/upbound/provider-azure-storage:v1
---
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-go-templating
spec:
  package: xpkg.crossplane.io/crossplane-contrib/function-go-templating:v0.9.0
```

After the package manifest is applied, verify readiness:

```bash
kubectl get providers.pkg.crossplane.io
kubectl get functions.pkg.crossplane.io
```

## Quick start

1. Clone this repository.
2. Install Crossplane plus the required providers/functions (see prerequisites above).
3. Review the public API shapes in platform/apis/landingzone/xrd.yaml, platform/apis/network/xrd.yaml, and platform/apis/storage/xrd.yaml.
4. Apply XRDs and compositions.
5. Apply example claims from examples/claims.
6. Inspect the claim -> public composite -> internal Azure composite -> managed resource chain.
7. Adapt platform-admin placeholders to your CAF-aligned environment.

Apply admin examples:

```bash
kubectl apply -f examples/platform-admin/platform-config.yaml
kubectl apply -f examples/platform-admin/provider-config.yaml
```

Apply XRDs and compositions:

```bash
kubectl apply -f platform/apis/landingzone/xrd.yaml
kubectl apply -f platform/apis/network/xrd.yaml
kubectl apply -f platform/apis/storage/xrd.yaml
kubectl apply -f platform/apis/azure/xazurelanding-zone/xrd.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/xrd.yaml
kubectl apply -f platform/apis/azure/xazurestorage-account/xrd.yaml

kubectl apply -f platform/functions/function-go-templating.yaml
kubectl apply -f platform/apis/landingzone/composition.yaml
kubectl apply -f platform/apis/network/composition.yaml
kubectl apply -f platform/apis/storage/composition.yaml
kubectl apply -f platform/apis/azure/xazurelanding-zone/composition.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/composition-corp.yaml
kubectl apply -f platform/apis/azure/xazurevirtual-network/composition-online.yaml
kubectl apply -f platform/apis/azure/xazurestorage-account/composition.yaml
```

Apply claims:

```bash
kubectl apply -f examples/claims/01-landing-zone-corp.yaml
kubectl apply -f examples/claims/02-network-corp.yaml
kubectl apply -f examples/claims/05-storage.yaml
```

## Maturity

This project is a starter pack and reference implementation. It is not production-ready as-is.

Production use requires explicit decisions for:

- authentication and identity model
- provider config lifecycle
- subscription vending
- management group placement
- Azure Policy
- RBAC
- multi-tenancy
- GitOps
- observability
- secret management
- testing and validation
- naming and tagging standards
- IPAM integration and network governance

## Roadmap

1. Validate public API shapes.
2. Implement minimal Azure managed resources.
3. Implement landing zone subscription vending.
4. Implement landing-zone-specific ProviderConfig lifecycle.
5. Implement Azure Network using native IPAM.
6. Add hub-connected corp network composition.
7. Add online or isolated network composition.
8. Add Storage implementation enhancements.
9. Add tests and validation.
10. Add contributor examples for additional platform products.

## More docs

- docs/architecture.md
- docs/api-design.md
- docs/product-model.md
- docs/bootstrap-assumptions.md
- docs/project-goals.md
- docs/non-goals.md
- CONTRIBUTING.md
