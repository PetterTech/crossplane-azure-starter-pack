# Tenant controls

These are documented prerequisites, not shipped RBAC. Apply them in the cluster that runs the platform.

- Only platform principals hold write verbs (create, update, patch, delete) on `Provider`, `DeploymentRuntimeConfig`, `ProviderConfig`, `ClusterProviderConfig`, `EnvironmentConfig`, `Subscription` XRs, raw managed resources, `Usage`, and any `*/status` subresource.
- In `crossplane-system`, only platform principals can create or update pods, use `pods/exec`, create `serviceaccounts/token`, or read secrets. Anyone with these can obtain a provider pod token and act as every identity that trusts its ServiceAccount (see `docs/identity-bootstrap.md`).
- Tenants cannot create namespaces.
- Tenants never reference `ClusterProviderConfig` objects; compositions always set the provider config reference explicitly, and there is no `default` ClusterProviderConfig.

## Vended subscription baseline

Subscriptions created by the `Subscription` API (`docs/apis/subscription.md`) are only as safe as the management group they land in. These are prerequisites, not shipped policy.

**Tags.** The `a5n-` prefix is reserved for the platform. `owner` is the tenant's accountable contact and is not trusted for automation.

**D1 Owner model.** Give each subscription 2-3 owners, as a PIM-eligible group. The platform identity-admin identity holds Contributor only: it holds no Owner and cannot assign roles beyond that grant.

**D2 Default management group.** Lock down the default management group with the policy baseline below, so a subscription that is not yet moved is still covered.

**D3 Delete protection.** Deliberately not in the XRs. Deleting a Subscription XR orphans the Azure subscription, and a platform operator cancels it. A subscription-scope lock needs a Drizzt-approved decision first.

**D4 DevTest vs Production.** `spec.workload` is immutable. Choose `Production` unless the work is non-production.

**D5 Management-group prerequisites.** Assign these at the target management group:

- Defender plans, deployed with DeployIfNotExists;
- activity log export;
- security contact;
- the Microsoft cloud security benchmark (MCSB) assignment;
- allowed locations;
- a tag policy for `costCenter` and `owner`.

After the first sandbox subscription is vended, check that the Defender plans are on.

## Network baseline

`VirtualNetwork` (`docs/apis/virtualnetwork.md`) creates a VNet, one subnet and an NSG. These controls are prerequisites, not shipped policy.

- **Defender for Key Vault.** Enable the plan "Microsoft Defender for Key Vaults" on the subscription (E8, K5), inherited via the management group by DeployIfNotExists. After the first sandbox deploy, treat the Defender recommendations as ground truth.
- **Diagnostic settings.** Not part of the XR. Assign the built-in policy "Deploy Diagnostic Settings for Key Vault to Log Analytics workspace" (DeployIfNotExists) with the categories `AuditEvent` and `AzurePolicyEvaluationDetails` plus `AllMetrics`, sent to Log Analytics (K1). Keep audit logs for at least 1 year.
- **Backstop policies.** Assign (audit or deny): "Key vaults should have soft delete enabled", "Azure Key Vault should use RBAC permission model", "Azure Key Vault should disable public network access", "Azure Key Vaults should use private link", and "Keys should have an expiration date" / "Secrets should have an expiration date".
- **Private DNS.** Create the zone `privatelink.vaultcore.azure.net` and assign the Azure Policy "Configure Azure Key Vaults with private endpoints" / private DNS zone DeployIfNotExists at the management group. Until then private vaults are unreachable by name (D6). Defender raises "Private endpoint should be configured for Key Vault" only if the endpoint is missing.
- **Data-plane roles.** The platform team assigns them outside this API (least privilege, for example Key Vault Secrets User or Key Vault Crypto User), because Contributor cannot assign roles (E1). A new vault is empty and unusable until someone does.
- **Accepted gaps.** Customer-managed keys and HSM are not offered (E14) and the SKU is fixed at standard; Premium and Managed HSM are out of scope.
- **Subnet join (E13).** The same subnet-join custom role applies to the vault private endpoint, with the same blast radius, quota (`count/keyvaults.platform.a5n.io`, e.g. `hard: {count/keyvaults.platform.a5n.io: "5"}`, illustrative) and subnet policy notes as for storage.
- **Purge protection.** Not toggleable: it cannot be turned off in this API. Deleting a vault leaves it soft-deleted and its name reserved for up to 90 days; platform admins cannot purge it earlier.

## Container Apps baseline

`ContainerApp` (`docs/apis/containerapp.md`) creates a Container Apps environment and one app. These controls are prerequisites, not shipped policy. Keldorn adds the conditions.

- **Defender for Containers.** Enable the plan "Microsoft Defender for Containers" on the subscription, inherited via the management group by DeployIfNotExists. After the first sandbox deploy, verify in Defender for Cloud that Container Apps are covered; if not, that is a documented gap. Other signals while no logs are collected: registry scanning and Defender CSPM, the Activity Log and cost anomalies.
- **Diagnostic settings.** Not part of the XR; the environment has no Log Analytics destination, so `ContainerAppConsoleLogs`, `ContainerAppSystemLogs` and metrics are not stored (LT-3, LT-4), and troubleshooting is expensive. Defender for Cloud will raise a finding on every deploy until the platform supplies a sink. Chosen option 1: a tenant DeployIfNotExists policy for Container Apps environments that sends the logs and metrics to Log Analytics; the alternative is a recorded exception (E15, to be logged by Elminster). Keep audit logs for at least 1 year.
- **Backstop policies.** Assign (audit or deny): Container Apps should only be accessible over HTTPS; Container Apps environments should use private link OR network injection (one of them, not both: the API keeps them exclusive); an allowed-registries policy so only approved public registries are pullable (the XR accepts any public registry; the image is the tenant's input); and a tags policy requiring `costCenter`, `owner` and `environment`. "Managed identity should be enabled" is audit-only: the default identity is `none`, so deny would block the default.
- **Private DNS.** Create the zone `privatelink.<region>.azurecontainerapps.io` per region and assign a DeployIfNotExists policy that registers the private endpoint's DNS zone group. Until then private apps are unreachable by name (D6).
- **Subnet join (E13).** The subnet-join custom role applies to the platform subnet of the private endpoint, and to the dedicated subnet of an injected environment (at least /27, empty, delegated to `Microsoft.App/environments`, supplied by the tenant), with the same blast radius, quota and subnet policy notes as for storage. The resolver refuses the platform's own private endpoint subnet as `infrastructureSubnetId`. No pre-grant exists for tenant-supplied subnets: any grant is a deliberate per-subnet identity-admin action, reviewed by Drizzt, and it decides which subnets a tenant may use. Quota: start with `hard: {count/containerapps.platform.a5n.io: "5"}` per tenant namespace; this is a starting point to tune from observed use, not a derived limit.
- **Accepted gaps.** No private registry or credentials, no secrets, no custom domains, no Easy Auth, no client certificate mode, no mTLS or custom TLS, no dedicated workload profiles. External ingress is Internet-open with no IP allowlist, and requires `deletionPolicy: Delete`. Zone redundancy is opt-in and needs injection. The app has no role until the platform assigns one (E1).

## Landing zone baseline

`LandingZone` (`docs/apis/landingzone.md`) lets a tenant create a new Azure subscription with no approval step. This is the accepted risk E3, owned by Petter Arnesen, cost owner the platform team. These controls are prerequisites, not shipped policy. Drizzt gates M1-M4.

- **M1-M4 are mandatory.** M1: billing scope, management group, tenant and role definition come from the `EnvironmentConfig` only (shipped). M2: CEL limits on names, `workload`, the tag allowlist (`costCenter`, `owner`, `environment`) and at most 10 tags, plus the stamped owner, namespace and XR uid tags (shipped). M3: `Orphan` is the default, with a `Usage` guard and a sweeper for subscriptions left behind (the guard and sweeper are platform-side). M4: namespace-scoped tenant RBAC: tenants get verbs on `landingzones` in their own namespace only, never on `Subscription` XRs, `ProviderConfig`, managed resources or any `*/status` (see the first list above).
- **M5 and M6 are required before the first non-sandbox deploy.** M5: a `ResourceQuota` per tenant namespace on `count/landingzones.platform.a5n.io` and `count/subscriptions.platform.a5n.io`; a starting point is `hard: {count/landingzones.platform.a5n.io: "2", count/subscriptions.platform.a5n.io: "2"}`, to tune from observed use. M6: the Azure-side subscription limit of the invoice section or management group, plus an alert on the subscription count (documented, platform-side). M7 (serialising vending) is recommended.
- **E16: Delete only for DevTest.** `deletionPolicy: Delete` is allowed only with `workload: DevTest` (CEL); Production is Orphan only. It applies to the storage account and key vault, never to the subscription or the resource group. Drizzt decides whether the option stays.
- **Subscriptions are never cancelled.** Deleting a landing zone leaves the subscription and its resource group in Azure; the platform team cancels the subscription and removes its identity by hand. Display names are not unique.
- **No lock.** The resource group has no ManagementLock (standing constraint); protect it with the management group's policies and RBAC.
- **Subscription baseline.** Everything under "Vended subscription baseline" applies to every landing zone subscription, because the vended subscription lands in that management group.
- **Network.** Storage accounts and key vaults are private only. The landing zone's own subnet carries their private endpoints; the platform subnet is rejected for them (`PrivateEndpointSubnetNotAllowed`), and so is any subnet outside the resource's own subscription (`PrivateEndpointSubnetWrongSubscription`). An existing virtual network named in `spec.virtualNetwork` must be in the landing zone's own subscription. Peering to the hub and hub DNS are platform concerns (D6). Subnet join in the vended subscription is covered by Contributor (D13, E13): **unverified until the sandbox**.
- **Private DNS.** The landing zone creates no DNS zone group. Create `privatelink.blob.core.windows.net` and `privatelink.vaultcore.azure.net` (hub DNS or tenant-level policy). Until a DeployIfNotExists policy or hub DNS registers the private endpoints, the storage account and key vault are unreachable by name.
- **Storage, Key Vault and Network baselines.** The children are the StorageAccount, KeyVault and VirtualNetwork APIs, so every control in "Network baseline" above applies to them: Defender for Storage and Defender for Key Vault, diagnostic settings (not part of the XRs), backstop policies, DNS zone groups and the subnet-join role. A landing zone subscription is only covered if the management group assigns them.
- **Tags.** The `a5n-*` tags on the storage account, key vault and virtual network carry the child XR's own identity (namespace, owner XR, uid), which differs from the resource group's tags (the landing zone's identity).
- **Unverified until the sandbox.** D13 (subnet join under Contributor) and that the Subscription stays in Azure (Orphan) when a landing zone is deleted. Do not rely on either before the first sandbox deploy.
- **Shared identity (E2, E9).** The Subscription is vended by the shared-tier identity. The `crossplane-system` restrictions above (pods, exec, token, secrets) are mandatory.
