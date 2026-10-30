# Tenant prerequisites

One checklist of everything the platform team must have in place outside the packages. None of it is shipped in an XR or composition: Defender, the Microsoft cloud security benchmark (MCSB) and Azure Policy are documented only (E5, owner Petter Arnesen). Detail and rationale live in `docs/tenant-controls.md`; accepted risks are in `docs/accepted-exceptions.md`.

**Mandatory** means the API is unsafe or does not work without it. **Recommended** means a known gap remains without it. "Before first non-sandbox deploy" items must be done before any production tenant.

Subscription-level and management-group items apply to the management group that vended subscriptions land in (`managementGroupId` in the `EnvironmentConfig`), so a new subscription inherits them.

## 1. Cluster and identity

| # | Control | Level | Depended on by |
|---|---|---|---|
| 1 | Only platform principals hold write verbs on `Provider`, `DeploymentRuntimeConfig`, `ProviderConfig`, `ClusterProviderConfig`, `EnvironmentConfig`, `Subscription` XRs, raw managed resources, `Usage` and `*/status`. Tenants cannot create namespaces and never reference a `ClusterProviderConfig`. | Mandatory | all APIs; `docs/tenant-controls.md` |
| 2 | In `crossplane-system`, only platform principals create or update pods, use `pods/exec`, create `serviceaccounts/token` or read secrets (a provider pod token acts as every identity that trusts the shared ServiceAccount, E2, E9). | Mandatory | `docs/identity-bootstrap.md`, `docs/apis/subscription.md`, `docs/apis/landingzone.md` |
| 3 | Bootstrap identities, federated credentials, runtime tiers and the three custom roles (hub connection, IPAM pool association, subnet join), granted by the identity-admin gate and never by a composition. | Mandatory | `docs/identity-bootstrap.md`; `VirtualNetwork` (E11), `StorageAccount`, `KeyVault`, `ContainerApp` (E13) |
| 4 | Crossplane RBAC aggregation for the `platform.a5n.io` kinds (install prerequisite). | Mandatory | `docs/identity-bootstrap.md` |
| 5 | One platform-writable `EnvironmentConfig` with real values applied; no real values in the repository. | Mandatory | `docs/environment-contract.md`; all APIs |
| 6 | Data-plane and workload role assignments made by the platform team outside the APIs (Contributor cannot assign roles, E1). | Mandatory for usable resources | `docs/apis/keyvault.md`, `docs/apis/containerapp.md` |
| 7 | Tenant namespace RBAC: verbs on the tenant kinds in their own namespace only. | Mandatory | `docs/apis/landingzone.md` (M4) |
| 8 | Platform-side checks: Usage guard and sweeper for orphaned subscriptions (M3); alert or monitoring query for managed resources that never reach `Synced` (missing ProviderConfig is silent on the resource). | Recommended (M3 sweeper: mandatory for `LandingZone`) | `docs/apis/subscription.md`, `docs/apis/landingzone.md` |

## 2. Quotas and limits

| # | Control | Level | Depended on by |
|---|---|---|---|
| 9 | `ResourceQuota` per tenant namespace on `count/landingzones.platform.a5n.io` and `count/subscriptions.platform.a5n.io` (M5). | Mandatory before first non-sandbox deploy | `LandingZone` (E3) |
| 10 | Azure-side subscription limit on the invoice section or management group, plus an alert on the subscription count (M6). | Mandatory before first non-sandbox deploy | `LandingZone` (E3) |
| 11 | `ResourceQuota` on the counts of `VirtualNetwork`, `StorageAccount`, `KeyVault` and `ContainerApp` per namespace; monitor subnet and IPAM pool sizes. | Recommended | E11, E13 |
| 12 | Serialise subscription vending (M7). | Recommended | `LandingZone` |

Values in the docs are illustrative starting points to tune from observed use.

## 3. Management group: Defender, benchmark and Azure Policy

| # | Control | Level | Depended on by |
|---|---|---|---|
| 13 | Microsoft Defender plans, deployed with DeployIfNotExists: Storage, Key Vaults, Containers. After the first sandbox subscription, confirm in Defender for Cloud that they are on. | Mandatory for production; recommended in sandbox | `StorageAccount`, `KeyVault`, `ContainerApp`, `Subscription` |
| 14 | MCSB initiative assignment (audit). | Mandatory for production | `Subscription`, `LandingZone` |
| 15 | Security contact. | Recommended | `Subscription` |
| 16 | Activity log export to Log Analytics; keep audit logs for at least one year. | Mandatory | `Subscription`, `LandingZone` |
| 17 | Lock down the default management group with the same baseline, so an unmoved subscription is covered (D2). | Recommended | `Subscription` |
| 18 | Policy: allowed locations (backstop for the optional `allowedLocations` key). | Mandatory | all APIs; `docs/environment-contract.md` |
| 19 | Policy: tags `costCenter` and `owner` (and `environment` for Container Apps) required. | Recommended | all APIs |
| 20 | Policy: diagnostic settings DeployIfNotExists for Key Vault (`AuditEvent`, `AzurePolicyEvaluationDetails`, `AllMetrics`), Storage and Container Apps environments to Log Analytics. Not part of any XR; without it Container Apps keep no logs (E15). | Mandatory for Key Vault; recommended for the rest | `KeyVault`, `StorageAccount`, `ContainerApp` |
| 21 | Policy backstops (audit or deny): Key Vault soft delete, RBAC model, public access disabled, private link, key and secret expiry; Container Apps HTTPS only, private link or network injection (not both), allowed registries; "Managed identity should be enabled" as audit only. | Recommended | `KeyVault`, `ContainerApp` |
| 22 | Policy: DeployIfNotExists private DNS zone groups for private endpoints. No XR creates one. | Mandatory for private resources to resolve by name | `StorageAccount`, `KeyVault`, `ContainerApp`, `LandingZone` |

## 4. Network and DNS

| # | Control | Level | Depended on by |
|---|---|---|---|
| 23 | Hub DNS or tenant-level policy, with private DNS zones `privatelink.blob.core.windows.net`, `privatelink.vaultcore.azure.net` and `privatelink.<region>.azurecontainerapps.io` per region (D6). | Mandatory | `StorageAccount`, `KeyVault`, `ContainerApp`, `LandingZone` |
| 24 | Hub routing isolation between tenant VNets (E12): route-table or association design, decided at sandbox time. | Mandatory before first non-sandbox deploy | `VirtualNetwork`, `docs/apis/virtualnetwork.md` |
| 25 | Subnet-join custom role granted per subnet by the identity-admin gate; no pre-grant for tenant-supplied subnets; subnet policy notes. | Mandatory for private endpoints on the platform subnet | `StorageAccount`, `KeyVault`, `ContainerApp` (E13) |
| 26 | Hub connection and IPAM pool rights (E11). | Mandatory | `VirtualNetwork` |

## 5. Before the first non-sandbox deploy

Complete items 9, 10 and 24 (M5, M6, E12). Also review the exceptions that name "first non-sandbox deployment" as a trigger in `docs/accepted-exceptions.md`, and confirm in the sandbox the items listed as unverified in `docs/identity-bootstrap.md` and `docs/apis/landingzone.md` (subnet join under Contributor, subscription orphaned not cancelled).
