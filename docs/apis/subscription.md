# Subscription

`Subscription` (`platform.a5n.io/v1alpha1`, namespaced) vends an Azure subscription for a namespace. Per `Subscription` the platform creates:

- the Azure subscription, placed in the platform's management group;
- a user-assigned managed identity (UAMI) and a federated identity credential that trusts the provider ServiceAccount;
- a Contributor role assignment for that identity on the subscription;
- a namespaced `ProviderConfig`, named after the Subscription, that acts as the identity.

Only the platform team creates Subscriptions (see `docs/tenant-controls.md`). The namespace is the trust domain: subscriptions of different trust belong in different namespaces.

## Example

```yaml
apiVersion: platform.a5n.io/v1alpha1
kind: Subscription
metadata:
  name: pettertech-sandbox
  namespace: pettertech-sandbox
spec:
  workload: DevTest
  tags:
    costCenter: "0000"
    owner: platform-team@example.com
    environment: sandbox
```

Billing scope, tenant, management group and identity location come from the platform `EnvironmentConfig`, never from the spec.

## Spec

All fields are optional.

| Field | Default | Notes |
| --- | --- | --- |
| `workload` | `Production` | `Production` or `DevTest`. Immutable once set. |
| `tags` | none | Only `costCenter`, `owner`, `environment`; at most 10 entries, values up to 256 characters. |

Name rules (CEL on the XRD): not `default`, no `platform-` prefix, lowercase letters, digits and `-`, starts with a letter, at most 30 characters. The Azure display name is `<namespace>-<name>` and is capped at 64 characters; a longer combination fails closed instead of being truncated (the limit is unverified, see below).

## Status

| Field | Meaning |
| --- | --- |
| `subscriptionId` | Azure subscription ID. |
| `subscriptionUid` | UID of this Subscription, so delete-and-recreate under the same name is detected. |
| `providerConfigName` | Name of the namespaced ProviderConfig; equals the Subscription name. |
| `identity.resourceId`, `.clientId`, `.principalId` | The UAMI. |
| `environment.location`, `.resourceGroupName` | Environment values recorded at first composition. Later EnvironmentConfig changes do not move existing resources. |

The values above are write-once (CEL), even for administrators. A tampered resource is recovered by deleting it. `Ready=True` means the subscription exists, the identity has access and the ProviderConfig exists.

## How vending works

1. The composition creates the subscription and associates it with the management group, then pins the subscription ID in XR status.
2. It creates the UAMI and federated credential in the platform identity resource group, then pins the identity.
3. The `verify-subscription` step compares the pinned ID with the ID the Subscription managed resource observes. Only when they are equal does it allow the Contributor `RoleAssignment` and the `ProviderConfig`. The first reconcile pins; a later one verifies.
4. The ProviderConfig is namespaced, in the Subscription's namespace, and named after the XR.

A namespace can hold several Subscriptions, each with its own identity and ProviderConfig. `spec.subscription` on building blocks is optional; it selects a Subscription by name when the namespace has more than one.

## Lifecycle

- **Orphan, never delete.** The subscription and its management group association use `managementPolicies: [Create, Observe, Update, LateInitialize]`; there is no `Delete`. Deleting the XR leaves the subscription in Azure.
- **Who cancels.** A platform operator cancels the subscription in Azure, by hand, after the namespace is retired. The starter pack does not do it.
- **Orphan sweeper.** Orphans are found by the `a5n-namespace`, `a5n-owner-xr` and `a5n-xr-uid` tags. The `a5n-` prefix is reserved and cannot be set from the spec. The tenant-controlled `owner` tag is not trusted for this.
- **Usage protection.** `Usage` objects stop the identity being deleted while its federated credential or role assignment exists.

## Threat model

- **Pin cross-check.** `verify-subscription` fails closed: on a mismatch between pinned and observed ID, `subscriptionVerified` is not set, so the RoleAssignment and ProviderConfig are removed from the desired state. *Unverified:* the removal behaviour has render tests only, not a live run.
- **XR name.** `default` and `platform-` are blocked by the XRD only. The composition adds a backstop for `default`.
- **Pre-existing ProviderConfig.** A ProviderConfig of the same name in the namespace could be adopted. Mitigation: only platform principals can write `ProviderConfig`.
- **Status writes.** Changing status needs platform-only RBAC on `*/status` (control E4 in `docs/tenant-controls.md`).
- **Display-name cap.** 64 characters, enforced by the composition. The Azure limit itself is unverified.

## Unverified

These Azure and Crossplane behaviours are not confirmed against a live tenant:

- the federated credential `parentId` handling;
- the `managementGroupId` form the provider accepts;
- how fast the Contributor assignment propagates;
- ABAC (role assignment condition) effects on the role assignment;
- `Usage` selectors resolving as intended;
- server-side apply honouring the write-once status rules.
