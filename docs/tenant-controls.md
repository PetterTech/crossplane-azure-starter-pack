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

- **Flow logs and NSG diagnostic settings.** Not composed (accepted exception E8, V2). Enable NSG flow logs or VNet flow logs through Network Watcher, and diagnostic settings on the NSG, from the management group.
- **DDoS protection.** Not composed (accepted exception E8, V5). Add a DDoS protection plan or IP protection where the workload is Internet-facing.
- **Backstop policies.** Assign at the management group: "Subnets should be associated with a Network Security Group" and "Network Watcher should be enabled".
- **Azure Firewall / NVA.** Not composed. The platform hub is the central control point for egress and inspection.
- **Tenant rights.** Tenants have no RBAC to add subnets or NSGs, so the VNet's single subnet and NSG are the only ones in the tenant namespace's path.

After the first sandbox subscription is vended and a VirtualNetwork is Ready, check that Defender for Cloud reports no unaddressed recommendations for the VNet, subnet and NSG.

## Storage baseline

`StorageAccount` (`docs/apis/storageaccount.md`) creates a storage account, containers and, when private, private endpoints. These controls are prerequisites, not shipped policy.

- **Private DNS.** Create the zones `privatelink.blob.core.windows.net` and `privatelink.file.core.windows.net`, and assign the Azure Policy "Configure Storage accounts to use private DNS zones" (DeployIfNotExists) at the management group. Until then private accounts are unreachable by name and fail closed (403). Follow-up D6: an optional environment key for zone IDs.
- **Defender for Storage.** Enable the plan (malware scanning, sensitive data threat detection).
- **Diagnostic settings.** Assign a DeployIfNotExists policy that sends blob, file, queue and table logs, plus the activity log, to Log Analytics.
- **Backstop policies.** Audit or deny public network access and shared key access.
- **Network access.** `networking: public` raises the Defender recommendation "Storage accounts should restrict network access". Any use needs a recorded exception.
- **Opt-outs.** `softDeleteDays` and `versioning: false` opt-outs raise BR-1 findings.
- **Redundancy.** LRS and ZRS are single-region. Geo-redundancy is the caller's choice.
- **Encryption keys.** Customer-managed keys are not offered; platform-managed keys apply (E14).
- **Subnet join (E13).** The per-subscription UAMI needs a custom role with only `Microsoft.Network/virtualNetworks/subnets/join/action`, at scope of the platform subnet and granted by the identity-admin gate (see `docs/identity-bootstrap.md`). Without it private endpoint creation fails closed (403). Blast radius: any shared-tier pod token can attach endpoints to the shared subnet and exhaust its IPs.
  - **Subnet policy.** Set `privateEndpointNetworkPolicies` on the shared platform subnet deliberately: `Enabled` (or `NetworkSecurityGroupEnabled`) applies NSGs/UDRs to private endpoint traffic; `Disabled` bypasses them. Choose per your network policy and document it with the subnet.
  - **Quota and monitoring.** Limit IP exhaustion with a per-namespace `ResourceQuota` on `count/storageaccounts.platform.a5n.io` (e.g. `hard: {count/storageaccounts.platform.a5n.io: "5"}`), and monitor free IPs in the subnet, alerting well before it is full. Size the subnet for quota × namespaces plus headroom.

After the first sandbox deploy, check that Defender for Cloud shows no new storage findings.
