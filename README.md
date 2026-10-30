# Crossplane Azure starter pack

A starter pack of Crossplane v2 APIs for Azure. Platform teams install it once; tenants then ask for Azure resources with small, namespaced Kubernetes objects (`LandingZone`, `StorageAccount`, `KeyVault`, ...) instead of raw managed resources. Defaults are safe: private networking, Orphan on delete, no GUIDs or provider details in tenant YAML.

All APIs are in the group `platform.a5n.io` (`v1alpha1`, namespaced). "PetterTech" is only the brand used in the examples; replace it with your own.

## Status

**Not yet verified against a real Azure sandbox.** The compositions are covered by `crossplane render` tests and, for the XRD rules, by throwaway kind clusters. Treat everything as a design until the first sandbox deploy. The items still unproven are listed under "Unverified until the first sandbox deploy" in [identity-bootstrap](docs/identity-bootstrap.md), and in each API page in `docs/apis/`: RBAC actions for hub connection and IPAM allocation, the fail-closed 403 behaviour, hub route-table isolation (E12), CEL acceptance on a real API server, live `ExtraResources` and Fatal behaviour, and subnet join under Contributor. Do not run it in production.

## Layers

Three Crossplane projects under `projects/`, each built and published as a Configuration:

| Project | APIs | Depends on |
| --- | --- | --- |
| `foundation` | `Subscription`, `VirtualNetwork` | providers and functions in `setup/` |
| `services` | `StorageAccount`, `KeyVault`, `ContainerApp` | providers and functions in `setup/` |
| `landingzone` | `LandingZone` | `foundation` and `services` |

A `Subscription` vends an Azure subscription with its own managed identity and `ProviderConfig`; the namespace is the trust domain. Building blocks pick a Subscription with the optional `spec.subscription`, or use the only Ready one in their namespace. A `LandingZone` composes a Subscription plus a virtual network, storage account and key vault in one object.

## Composition ladder

1. **function-patch-and-transform** (P&T) first.
2. **function-kro** when resources are conditional or depend on each other's observed state.
3. **function-go-templating** only as a justified, logged exception. The pack has exactly two: the shared subscription resolver (E6) and `verify-subscription` (E10). See [accepted-exceptions](docs/accepted-exceptions.md).

## Install order

1. Install Crossplane v2 and apply `setup/`: `providers.yaml`, `functions.yaml`, `deployment-runtime-config.yaml`, `clusterproviderconfigs.yaml`.
2. Bootstrap identities, federated credentials, runtime tiers and custom roles: [identity-bootstrap](docs/identity-bootstrap.md).
3. Fill in and apply `setup/environmentconfig.yaml` with your real values (never commit them): [environment-contract](docs/environment-contract.md).
4. Put the platform controls in place (RBAC, quotas, Defender, policy): [tenant-prerequisites](docs/tenant-prerequisites.md), [tenant-controls](docs/tenant-controls.md).
5. Install the Configurations in this order: `foundation`, `services`, `landingzone`. `landingzone` declares both others as dependencies.

## Getting started in 10 minutes

Assumes steps 1-5 are done and you are the platform team (tenants cannot create namespaces or Subscriptions).

1. **A tenant namespace**, with tenant RBAC on the `platform.a5n.io` kinds in it:

   ```sh
   kubectl create namespace pettertech-sandbox
   ```

2. **A minimal LandingZone.** An empty spec creates only a Subscription named after the landing zone, and its resource group:

   ```yaml
   apiVersion: platform.a5n.io/v1alpha1
   kind: LandingZone
   metadata:
     name: pettertech-minimal
     namespace: pettertech-sandbox
   spec: {}
   ```

   Wait for `kubectl -n pettertech-sandbox get landingzone,subscription` to show `READY=True`. Nothing else is composed until the Subscription is Ready.

3. **A StorageAccount and a KeyVault.** With one Ready Subscription in the namespace, `spec.subscription` can be omitted. Every field has a safe default (private, with a private endpoint in the platform subnet):

   ```yaml
   apiVersion: platform.a5n.io/v1alpha1
   kind: StorageAccount
   metadata:
     name: pettertech-minimal
     namespace: pettertech-sandbox
   spec: {}
   ---
   apiVersion: platform.a5n.io/v1alpha1
   kind: KeyVault
   metadata:
     name: pettertech-minimal
     namespace: pettertech-sandbox
   spec: {}
   ```

   Private resources need the platform subnet in the `EnvironmentConfig` (`subnetId`), otherwise composition fails closed with `SubnetNotConfigured`.

More: a minimal and an explicit example for every API are in `projects/*/examples/`.

## Docs

- API pages: [Subscription](docs/apis/subscription.md), [VirtualNetwork](docs/apis/virtualnetwork.md), [StorageAccount](docs/apis/storageaccount.md), [KeyVault](docs/apis/keyvault.md), [ContainerApp](docs/apis/containerapp.md), [LandingZone](docs/apis/landingzone.md)
- [Environment contract](docs/environment-contract.md)
- [Identity bootstrap](docs/identity-bootstrap.md)
- [Tenant prerequisites](docs/tenant-prerequisites.md)
- [Tenant controls](docs/tenant-controls.md)
- [Accepted exceptions](docs/accepted-exceptions.md)
- [Migration from the javazone and nic branches](docs/MIGRATION.md)
- [Releasing](docs/RELEASING.md)

## Validate

```sh
BUILD=0 scripts/validate.sh   # static checks; BUILD=1 also runs `crossplane project build`
```

Each API has a test script at `projects/<project>/tests/<api>/run.sh` that renders the composition and validates the examples against the XRD.
