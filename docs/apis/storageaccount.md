# StorageAccount

`StorageAccount` (`platform.a5n.io/v1alpha1`, namespaced) creates, in the namespace's Subscription:

**Read this first.** The private endpoint targets blob (file for `FileStorage`). Shared key access is off, so Azure SMB file access with the account key is not possible (Entra ID only). Private accounts have no private DNS zone group (see below), so until the platform provides DNS, clients inside the network get a 403 by account name; that is a known limit, not a fault of your resource. The private endpoint must be in the same region as its subnet, so `location` must match the platform subnet's region (a mismatch fails in Azure).

- a hardened storage account;
- the blob containers in `spec.parameters.containers` (not for `FileStorage`);
- a private endpoint for blob (file for `FileStorage`) in the platform subnet, only when `networking` is `private` (the default) and the platform has a subnet. No private endpoint is ever created without a subnet.

There is no ManagementLock. Everything is tagged with `a5n-namespace`, `a5n-owner-xr` and `a5n-xr-uid`, plus `costCenter`, `owner` and `environment` from `spec`.

## Example

See `projects/services/examples/storageaccount/storageaccount.yaml`.

## Which Subscription

The shared resolver (`projects/foundation/apis/_shared/resolver.md`) uses `spec.subscription`, or else the only Ready `Subscription` in the namespace, and pins it in `status`. Every managed resource uses the namespaced `ProviderConfig` named after that Subscription.

## Pipeline

`environment-configs` -> `function-kro` (account, containers, conditional private endpoint; kro reads the pinned `status.environment` through an `externalRef` to the XR itself) -> `resolve-subscription` (shared resolver, inlined copy) -> `auto-ready`.

Reconcile 1 only pins the Subscription and the environment. From the second, the account is created; the containers and the private endpoint follow once the account reports its ID.

## Environment keys

| Key | Use |
| --- | --- |
| `location`, `resourceGroupName` | where the resources go (pinned) |
| `subnetId` | the private endpoint subnet; required only for `networking: private` (pinned) |
| `allowedLocations` | optional, comma separated; checked when the location is first pinned |

A private account without a valid `subnetId` (missing, placeholder or malformed) fails closed: the resolver result is Fatal with `SubnetNotConfigured` (visible in the `Synced` message), nothing is composed or pinned, and `Ready` is not reported (it would otherwise be True with nothing composed). It composes once the platform sets the subnet. A pinned account whose subnet later disappears from the environment keeps its endpoint and reports drift (`EnvironmentDrift`); a public account flipped to private gets no endpoint and `EnvironmentValid=False`, while public access is switched off.

## Private endpoint subnet

`parameters.privateEndpointSubnetId` (immutable, `networking: private` only) puts the private endpoint in a subnet you name, which is how a `LandingZone` places it in its own virtual network (`docs/apis/landingzone.md`). The platform's shared subnet is rejected (`PrivateEndpointSubnetNotAllowed`), and so is a subnet outside the resource's own subscription (`PrivateEndpointSubnetWrongSubscription`). The identity of the subscription needs the subnet-join right on that subnet (E13); the platform pre-grants none for tenant-supplied subnets.

## Private DNS (known gap)

The composition creates no private DNS zone group, because the EnvironmentConfig contract has no zone-ID key. Without a zone group the blob name does not resolve to the private IP, and the public name is blocked by the firewall: private accounts fail closed (403 by name) until an Azure Policy (DeployIfNotExists) or a future optional environment key supplies the zone group. Plan for this before relying on private accounts.

## Deletion and adoption by name

`spec.deletionPolicy` is `Orphan` (default) or `Delete`, as for the Subscription (`managementPolicies` without `Delete`; `.m` MRs have no `deletionPolicy`).

- `Orphan`: deleting the resource leaves the account and its containers, with all data, in Azure. The private endpoint is removed. Nobody manages the account afterwards.
- `Delete`: the account and containers are deleted in Azure; only soft delete (see below) can bring data back.
- Adoption by name: the derived account name depends only on the namespace, the resource name and the Subscription. Re-creating a resource with the same name derives the same account name and adopts the orphaned account with its data and settings. Set `parameters.name` to pick another, or delete the leftover account first.

## Hardening

| Setting | Value |
| --- | --- |
| HTTPS only, minimum TLS | true, TLS 1.2 |
| Shared key access | disabled (Entra ID only), OAuth by default |
| Anonymous blob access | disabled; containers are `private` |
| Public network access | only with `networking: public` |
| Network rules | default action Deny, no bypass; `allowedIpRanges` only when public, prefixes /16 or narrower (CEL) |
| Soft delete / versioning | `softDeleteDays` (at least 1, blobs and containers) and `versioning`, from spec; not for `FileStorage`. `versioning: false` stays a caller opt-out and will raise Defender for Cloud and backup-resilience findings |
| SFTP, NFSv3, hierarchical namespace, local users | disabled |
| Cross-tenant replication | disabled |

## Naming

`spec.parameters.name` (3-24 lowercase letters and digits) is used as given on creation. It can only be set when the resource is created; adding, changing or removing it later is rejected (CEL), so an existing account is never swapped. Otherwise the name is `st` plus 22 characters from `random.seededString`, seeded on namespace, name and subscriptionId: deterministic, always 24 lowercase alphanumeric characters, different per Subscription and per resource name. The name is recorded in `status.accountName` (write-once) and the composition reads the pin first (pin, then `parameters.name`, then the derived name), so it never changes even if the derivation changes.

## Status

`accountName`, `resourceId`, `privateEndpointId` (private only), `endpoints.blob` and `endpoints.file`, and the write-once pins (`subscription`, `subscriptionUid`, `subscriptionId`, `environment`, `accountName`).

## Schema deviations

- The XRD has an added rule: `containers` need `accountKind` StorageV2 or BlockBlobStorage, because `FileStorage` has no blob service.
- `status.environment` gains `subnetId`; `status.accountName` is write-once.
- New spec field `deletionPolicy` (Delete|Orphan, default Orphan); `softDeleteDays` minimum is 1; `allowedIpRanges` prefixes must be /16 or narrower.
- No private DNS zone group (see "Private DNS"). The EnvironmentConfig contract has no key for a zone ID and changing it needs a platform decision. Until then the private endpoint resolves only if an Azure Policy (DeployIfNotExists) or a future optional environment key (for example the blob private DNS zone ID) supplies the zone group.

## Threat model

- The resolver is the trust boundary: it verifies the Subscription's UID and subscriptionId, and pins them (CEL write-once).
- Data exposure: private by default; public requires an explicit `networking: public` and a firewall that denies all but `allowedIpRanges`. CEL rejects `allowedIpRanges` with private.
- Credential leakage: shared keys and SAS-by-key are off; access is Entra ID RBAC only. Anonymous access is off at account and container level.
- Transport: HTTPS and TLS 1.2 only.
- Cross-subscription private endpoint: the endpoint joins the platform subnet, which lives outside the tenant Subscription. The per-subscription identity needs subnet-join rights there; without them the create fails closed with 403.
- Data loss: soft delete and versioning limit damage from deletes; there is no ManagementLock, so deleting the XR deletes the account.
- A tenant cannot choose the subnet, region default or resource group default; they come from the EnvironmentConfig (and the location only from the allowed list).
- Fail closed: unresolved subscription, environment or location is Fatal and stops composition.

## Unverified until the first sandbox deploy

- `storageUseAzureAD` on the ProviderConfig: with shared key disabled, data-plane operations (container creation) may need it. The Subscription composition does not set it.
- upjet treating `bypass: []` as None.
- ipRules limits (azurerm rejects /31 and /32 ranges, single IPs are accepted).
- Subnet-join permission for the per-subscription identity on the platform subnet (fails with 403).
- Private endpoint group IDs (`blob`, `file`) and the missing DNS zone group.
- Live kro behaviour for optional and empty lists, and for `forEach` collections (no `readyWhen` is used; auto-ready covers them).
- Stability of `random.seededString` across function-kro upgrades; a changed name would not move the existing account, because `crossplane.io/external-name` is kept, but would change it for new ones.
- Premium and FileStorage `blobProperties` handling.
- A Fatal result keeping the composed resources live (shown under render only).
- `Orphan` on a live provider: that the missing `Delete` management policy really keeps the account in Azure (only the policy list was verified, on kind).

## Tests

`projects/services/tests/storageaccount/run.sh` renders every reconcile stage with `crossplane render`, including the fail-closed cases (no or ambiguous Subscription, not Ready, pin mismatch, missing or placeholder environment, private without subnet, location not allowed) and XRD CEL validation (premium/kind, name length, ipRules with private). `kind-cel.sh` runs the write-once status and immutability rules on a throwaway kind cluster.

`live.sh` installs Crossplane 2.4.3 and the pinned functions on a throwaway kind cluster with the provider CRDs only (no provider, no Azure) and checks the composed resources against the real CRDs, the name pin, `deletionPolicy`, and the fail-closed private case, with the managed resources' status patched by hand. It proves composition behaviour, not anything in Azure.
