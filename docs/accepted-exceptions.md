# Accepted exceptions

Every risk or deviation accepted knowingly, in one place. The IDs refer to the decisions log kept by the platform team (`.squad/decisions.md`, not part of this repository); this page summarises effect and revisit conditions without repeating the internals. Controls that reduce these risks are in `docs/tenant-prerequisites.md` and `docs/tenant-controls.md`.

Owner is Petter Arnesen unless stated. "Sandbox" items are unverified until the first sandbox deploy.

## Identity and access

| ID | Exception | Why | Revisit when |
|---|---|---|---|
| E1 | Contributor on each vended subscription, not a least-privilege role. Contributor cannot assign roles, so no API grants roles. | One role for all APIs. | A composition needs a role assignment, or the first production release. |
| E2 | The shared-tier provider ServiceAccount is trusted by every per-subscription identity; the shared runtime is a trust boundary. | Per-subscription runtimes do not scale. | The tier split fails, or after a shared-runtime incident. |
| E9 | The vending identity trusts the shared-tier subject (deviation from vending on its own runtime; reviewed by Drizzt). | A `ClusterProviderConfig` cannot pick a runtime. | With E3, or when Subscription can run in its own tier. |
| E4 | The resolver trusts XR-supplied subscription names within a namespace; the namespace is the trust domain. | Simplicity; bounded by the write-once pin and platform-only Subscription RBAC. | A pin bypass is found. |
| E11 | Per-subscription identities hold narrow hub-connection and IPAM-pool custom roles. | Contributor cannot write them. | First non-sandbox deploy, a hub or pool change, or an incident. |
| E13 | Per-subscription identities may join subnets on the platform subnet. Tenant-supplied subnets get no pre-grant. | Contributor cannot join a subnet in another subscription. | Sandbox result, first non-sandbox deploy. |

## Self-service and lifecycle

| ID | Exception | Why | Revisit when |
|---|---|---|---|
| E3 | Self-service `LandingZone` with no approval step; cost owner is the platform team. | Tenant self-service. M1-M4 mandatory; M5, M6 before first non-sandbox deploy. | More than one namespace with more than five subscriptions, an external tenant, a billing-limit warning, quarterly; expires after six months or the first production tenant. |
| E16 | `LandingZone` `deletionPolicy: Delete` allowed for `DevTest` only; never deletes the subscription or resource group. Accepted by Drizzt. | Sandbox clean-up. | First production tenant, E3 review. |
| (D5) | `StorageAccount` `deletionPolicy` defaults to `Orphan`; `Delete` removes all data. | Consistency with Subscription. | With the ManagementLock decision below. |
| (D13) | Subnet join under Contributor and subscription orphaning (not cancelling) on landing zone delete are assumed. | Design assumption. | Sandbox: verify before relying on either. |

## Network and security posture

| ID | Exception | Why | Revisit when |
|---|---|---|---|
| E5 | Tenant RBAC, ResourceQuota, Defender, MCSB and Azure Policy are documented, not shipped. | Tenant-level concerns. | The first adopter outside the platform team. |
| E8 | Residual low and medium compliance items stay documentation only (flow logs, DDoS, Key Vault Defender follow-up, customer-managed keys for storage). | Tenant-level or optional. | Per compliance review. |
| E12 | No hub route-table isolation between tenant VNets is shipped. | It is hub topology. | Sandbox result; required before first non-sandbox deploy. |
| E14 | Platform-managed keys only; no customer-managed keys or HSM; Key Vault SKU is standard. | Scope. | First adopter needing CMK. |
| E15 | Container Apps: no log destination; external ingress is Internet-open with no IP allowlist or built-in auth and accepts any public image (requires `deletionPolicy: Delete`); no Easy Auth, client certificates, mTLS or dedicated workload profiles. | Scope; no log sink in the pack. | A log sink exists, or first non-sandbox deploy. |
| (D6) | No private DNS zone group is created; private resources are unreachable by name until the platform supplies DNS. | DNS is tenant-level. | An optional environment key for zone IDs is added. |

## Composition and tooling

| ID | Exception | Why | Revisit when |
|---|---|---|---|
| E6 | One go-templating step, the shared subscription resolver, in each building block. Other steps use patch-and-transform or function-kro. | Optional `spec.subscription` needs list, filter and fail. Fallback is a required field. | function-kro supports listing, or the field is made required. |
| E10 | A second go-templating step, `verify-subscription`, in the Subscription composition only. | It must fail closed (Fatal) on a pinned-ID mismatch; function-kro would drop and delete resources. | function-kro gains a fail-closed gate; expires with E6. |
| E7 | function-kro v0.3.0 (pre-release) pinned exactly. | Needed for conditional private endpoints. | A v1 release. |
| Standing | No `ManagementLock` in any composition, including the landing zone resource group. | Locks need identity-plane rights the shared tier and vending identity must not hold. | A separate Drizzt-approved decision names the identity. |

## Reading the log

- A trigger such as "first non-sandbox deploy" means the exception must be re-reviewed and its mandatory conditions met before that deploy.
- Exceptions without a stated expiry are reviewed at least quarterly with E3.
- Changing or accepting an exception needs a new entry in the decisions log with a named owner; this page is updated afterwards.
