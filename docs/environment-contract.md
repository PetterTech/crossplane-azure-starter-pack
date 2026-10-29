# Environment contract

## 1. Purpose

All environment-specific values (tenant, region, network, identity locations) live in one place: the cluster-scoped `EnvironmentConfig` named `platform-environment`, shipped as a placeholder template in `setup/environmentconfig.yaml`. Compositions never hard-code these values.

There is exactly **one EnvironmentConfig per cluster**, writable only by the platform team (see `docs/tenant-controls.md`). `scripts/validate.sh` enforces that `setup/` holds exactly one and that every value is a `<PLACEHOLDER>`.

## 2. Keys

| Key | Meaning | Set by | Identity-sensitive |
|---|---|---|---|
| `tenantId` | Entra tenant ID | Platform team | Y |
| `location` | Default Azure region | Platform team | N |
| `resourceGroupName` | Default resource group for adopters | Platform team | N |
| `subnetId` | Default subnet for services outside a landing zone | Platform team | N |
| `ipamPoolId` | IPAM pool for VNet addressing | Platform team | N |
| `hubVirtualHubId` | Virtual hub for peering | Platform team | N |
| `billingScopeId` | Billing scope for subscription vending | Platform team | Y |
| `managementGroupId` | Target management group for vended subscriptions | Platform team | Y |
| `identitySubscriptionId` | Subscription that holds vended UAMIs | Platform team | Y |
| `identityResourceGroupName` | Resource group that holds vended UAMIs | Platform team | Y |
| `oidcIssuerUrl` | Cluster OIDC issuer for federated credentials | Platform team | Y |
| `providerServiceAccountSubject` | Subject of the shared provider ServiceAccount; must match `setup/deployment-runtime-config.yaml` | Platform team | Y |
| `subscriptionRoleDefinitionId` | Contributor role definition granted to each UAMI | Platform team | Y |
| `allowedLocations` (optional) | Comma-separated permitted regions | Platform team | N |

## 3. Optional `allowedLocations`

- Comma-separated list of regions.
- When set and the effective `location` is not listed, the composition sets `EnvironmentValid=False` with reason `LocationNotAllowed` and **fails closed** (creates nothing).
- When absent, there is no restriction.
- Azure Policy (allowed locations) remains the documented backstop; this check does not replace it.

*Design intent: enforcement lands with the composition changes in later PRs.*

## 4. User overrides

Users may override only two values, in `spec.parameters`:

- `location`
- `resourceGroupName`

When omitted, the environment value is used. Users can never override subnet, hub, IPAM pool or any identity value.

## 5. Status and conditions (design intent)

*The composition behaviour in this section arrives in later PRs; it is not implemented by the environment-contract PR.*

- `status.environment` records the effective `location` and `resourceGroupName`, **written once** when the XR is first composed (write-once pin).
- `EnvironmentValid` condition reports whether the environment satisfies the contract. Documented reason: `LocationNotAllowed`. Other reasons are not yet defined (unverified).
- `EnvironmentDrift` is an informational condition set when the EnvironmentConfig later differs from the pinned values. Drift does not move or recreate existing resources.

Editing the EnvironmentConfig therefore only affects newly composed XRs.

## 6. How compositions consume it

Add as the first pipeline step, before other functions (`function-environment-configs`):

```yaml
- step: environment
  functionRef:
    name: function-environment-configs
  input:
    apiVersion: environmentconfigs.fn.crossplane.io/v1beta1
    kind: Input
    spec:
      environmentConfigs:
        - type: Reference
          ref:
            name: platform-environment
```

Always select by `Reference` and name; never by label selector. Values appear under the context key `apiextensions.crossplane.io/environment`. Patch-and-transform reads them with `FromEnvironmentFieldPath`. function-kro cannot read the environment context (verified in the PR 7 spike); a kro graph reads values through an `externalRef` to this EnvironmentConfig (`apiVersion: apiextensions.crossplane.io/v1beta1`, `kind: EnvironmentConfig`).

## 7. Applying real values

Real values are applied out-of-band, never committed:

- a kustomize overlay kept outside this repository, or
- a private apply of a filled-in copy of `setup/environmentconfig.yaml`.

Audit the **live object** (`kubectl get environmentconfig platform-environment -o yaml`), not Git, because Git only holds placeholders.

## 8. Trust boundary

Identity-sensitive keys (`tenantId`, `billingScopeId`, `managementGroupId`, `identity*`, `oidcIssuerUrl`, `providerServiceAccountSubject`, `subscriptionRoleDefinitionId`) define who may act as what. Changing any of them is a **trust-boundary change** that needs platform-admin review; CODEOWNERS on `setup/` is recommended.

Conditions:

- Compositions read these values only from the environment context, never from XR `spec`.
- The federated credential audience is fixed to `api://AzureADTokenExchange` in the composition, not configurable.
- `subscriptionRoleDefinitionId` must be the Contributor role definition (`b24988ac-6180-42a0-ab88-20f7382dd24c`) and must match the role definition in the ABAC condition in `docs/identity-bootstrap.md`.
- Tenants must have no write RBAC on `environmentconfigs`.

## LandingZone note

A LandingZone's private endpoints use its own VNet subnet, referenced through a typed `virtualNetwork` reference, not the environment `subnetId`. *Design intent; not yet implemented.*
