# KeyVault

`KeyVault` (`platform.a5n.io/v1alpha1`, namespaced) creates, in the namespace's Subscription:

**Read this first.** Access is Azure RBAC only and this API grants no roles (Contributor cannot assign roles, E1): the platform team assigns data-plane roles outside it, so a new vault is empty and unusable until someone does. Private vaults have no private DNS zone group (see below), so until the platform provides DNS, clients inside the network can't resolve the vault by name; that is a known limit, not a fault of your resource. Purge protection is on: deleting a vault leaves it soft-deleted and its name reserved for up to 90 days. The private endpoint must be in the same region as its subnet, so `location` must match the platform subnet's region.

- a hardened key vault;
- a private endpoint (group `vault`) in the platform subnet, only when `networking` is `private` (the default) and the platform has a subnet. No private endpoint is ever created without a subnet.

There is no ManagementLock and no role assignment. Everything is tagged with `a5n-namespace`, `a5n-owner-xr` and `a5n-xr-uid`, plus `costCenter`, `owner` and `environment` from `spec`. Diagnostic settings are not part of the XR (see `docs/tenant-controls.md`).

## Example

See `projects/services/examples/keyvault/keyvault.yaml`.

## Which Subscription

The shared resolver (`projects/foundation/apis/_shared/resolver.md`) uses `spec.subscription`, or else the only Ready `Subscription` in the namespace, and pins it in `status`. Every managed resource uses the namespaced `ProviderConfig` named after that Subscription.

## Pipeline

`environment-configs` -> `function-kro` (vault, conditional private endpoint; kro reads the pinned `status.environment` through an `externalRef` to the XR itself) -> `resolve-subscription` (shared resolver, inlined copy) -> `auto-ready`.

Reconcile 1 only pins the Subscription and the environment. From the second, the vault is created; the private endpoint follows once the vault reports its ID.

## Environment keys

| Key | Use |
| --- | --- |
| `location`, `resourceGroupName` | where the resources go (pinned) |
| `tenantId` | Entra tenant of the vault; required, must be a GUID (pinned) |
| `subnetId` | the private endpoint subnet; required only for `networking: private` (pinned) |
| `allowedLocations` | optional, comma separated; checked when the location is first pinned |

A missing, placeholder or malformed `tenantId` is Fatal (`EnvironmentInvalid`). A private vault without a valid `subnetId` (missing, placeholder or malformed) fails closed: the resolver result is Fatal with `SubnetNotConfigured` (visible in the `Synced` message), nothing is composed or pinned, and `Ready` is not reported (it would otherwise be True with nothing composed). It composes once the platform sets the subnet. A pinned vault whose subnet later disappears from the environment keeps its endpoint and reports drift (`EnvironmentDrift`); a public vault flipped to private gets no endpoint and `EnvironmentValid=False`, while public access is switched off.

## Private DNS (known gap, D6)

The composition creates no private DNS zone group, because the EnvironmentConfig contract has no zone-ID key. Without a zone group `<name>.vault.azure.net` does not resolve to the private IP, and the public path is blocked: private vaults are unreachable by name until an Azure Policy (DeployIfNotExists) for `privatelink.vaultcore.azure.net` or a future optional environment key supplies the zone group.

## Deletion and adoption by name

`spec.deletionPolicy` is `Orphan` (default) or `Delete`, as for the Subscription (`managementPolicies` without `Delete`; `.m` MRs have no `deletionPolicy`).

- `Orphan`: deleting the resource leaves the vault, with its secrets, keys and certificates, in Azure. The private endpoint is removed. Nobody manages the vault afterwards.
- `Delete`: the vault is deleted. Purge protection is on, so it stays soft-deleted for `softDeleteDays` (up to 90 days), its name stays reserved and nobody can purge it earlier. Re-creating a vault with the same name may fail until the retention ends; azurerm may instead auto-recover a soft-deleted vault of the same name (`recover_soft_deleted_key_vaults` defaults to true), which acts as an adoption path. Real behaviour is unverified until the sandbox deploy.
- Adoption by name: the derived vault name depends only on the namespace, the resource name and the Subscription. Re-creating a resource with the same name derives the same vault name and adopts an orphaned vault with its contents and settings. Set `parameters.name` to pick another, or delete the leftover vault first.

## Hardening

| Setting | Value |
| --- | --- |
| Authorization | Azure RBAC (`rbacAuthorizationEnabled`), no access policies |
| Purge protection, soft delete | always on; `softDeleteDays` 7-90 (default 90), fixed after creation |
| SKU | standard |
| Public network access | only with `networking: public` |
| Network ACLs | default action Deny, bypass None; `allowedIpRanges` only when public, prefixes /16 or narrower (CEL) |
| VM, disk encryption, template deployment access | disabled |
| Customer-managed keys | not offered (E14) |

## Naming

`spec.parameters.name` (3-24 lowercase letters, digits and single hyphens; starts with a letter, ends with a letter or digit) is used as given on creation. It can only be set when the resource is created; adding, changing or removing it later is rejected (CEL), so an existing vault is never swapped. Otherwise the name is `kv` plus 22 characters from `random.seededString`, seeded on namespace, name and subscriptionId: deterministic, always 24 lowercase alphanumeric characters starting with a letter, different per Subscription and per resource name. The name is recorded in `status.vaultName` (write-once) and the composition reads the pin first (pin, then `parameters.name`, then the derived name), so it never changes even if the derivation changes.

## Status

`vaultName`, `resourceId`, `vaultUri`, `privateEndpointId` (private only), and the write-once pins (`subscription`, `subscriptionUid`, `subscriptionId`, `environment`, `vaultName`).

## Schema deviations

- The `name` pattern is lowercase only (the Azure rule is case-insensitive, but a lowercase name avoids two names that differ only in case).
- `status.environment` gains `tenantId` and `subnetId`; `status.vaultName` is write-once.
- No private DNS zone group (see "Private DNS"); no role assignment (E1); no diagnostics in the XR (K1).
- `softDeleteDays` is passed as a number (`double`) because the provider schema type is number.

## Threat model

- The resolver is the trust boundary: it verifies the Subscription's UID and subscriptionId, and pins them (CEL write-once). The tenant is taken from the platform EnvironmentConfig and pinned; a tenant cannot choose it.
- Data exposure: private by default; public requires an explicit `networking: public` and a firewall that denies all but `allowedIpRanges`. CEL rejects `allowedIpRanges` with private.
- Authorization: Azure RBAC only; no access policies, no bypass for Azure services.
- Cross-subscription private endpoint: the endpoint joins the platform subnet, which lives outside the tenant Subscription (E13). The per-subscription identity needs the subnet-join role there; without it the create fails closed with 403.
- Data loss: soft delete and purge protection (not toggleable) limit damage from deletes; there is no ManagementLock, so deleting the XR with `deletionPolicy: Delete` deletes the vault (recoverable for the retention period) and `Orphan` leaves it unmanaged.
- Expiry dates and rotation of keys and secrets are tenant responsibilities (data-plane); Defender flags them and the Azure Policy expiry audits cover them.
- A tenant cannot choose the subnet, tenant, region default or resource group default; they come from the EnvironmentConfig (and the location only from the allowed list).
- Fail closed: unresolved subscription, environment or location is Fatal and stops composition.

## Unverified until the first sandbox deploy

- Subnet-join permission for the per-subscription identity on the platform subnet (fails with 403), E13.
- The private endpoint group ID `vault` and the missing DNS zone group.
- upjet handling of `networkAcls.bypass: None` and of `ipRules` (azurerm rejects /31 and /32 ranges, single IPs are accepted).
- Whether the provider accepts the default `Deny` ACL with `publicNetworkAccessEnabled: false` and no ipRules at creation.
- Live behaviour of `Orphan` and `Delete` against a real provider with purge protection (only the policy lists were verified, on kind).
- Stability of `random.seededString` across function-kro upgrades; a changed derivation would not move the existing vault, because `crossplane.io/external-name` is pinned in `status.vaultName`, but would change it for new ones.
- A Fatal result keeping the composed resources live (shown under render only).
- A soft-deleted vault of the same name blocking re-creation, or being auto-recovered by azurerm (`recover_soft_deleted_key_vaults`).

## Tests

`projects/services/tests/keyvault/run.sh` renders every reconcile stage with `crossplane render`, validates the composed Vault and PrivateEndpoint against the provider v2.8.0 CRDs (objects versus lists), and covers the fail-closed cases (no or ambiguous Subscription, not Ready, pin mismatch, missing or placeholder environment and tenantId, private without subnet, location not allowed), the name derivation and pin order, and XRD CEL validation (name pattern and length, ipRules with private, prefixes /0-/15, softDeleteDays range). `kind-cel.sh` runs the write-once status and immutability rules, including adding a name, on a throwaway kind cluster.

`live.sh` installs Crossplane 2.4.3 and the pinned functions on a throwaway kind cluster with the provider CRDs only (no provider, no Azure) and checks the composed resources against the real CRDs, the name pin, a function-kro restart, the private/public flip in both directions, rejection of adding a name, `deletionPolicy`, and the fail-closed `SubnetNotConfigured` case, with the managed resources' status patched by hand. It proves composition behaviour, not anything in Azure.
