# Identity bootstrap

The platform uses three bootstrap identities, created outside Crossplane by a platform admin. Everything below uses placeholders; never commit real tenant, subscription, client, billing or management group IDs. There are no secrets anywhere (no client secrets, no `secretRef`, no `Secret` credentials): all authentication is workload identity federation (`OIDCTokenFile`).

The ClusterProviderConfigs are in `setup/clusterproviderconfigs.yaml`: exactly three (`platform-vending`, `platform-identity-admin`, `platform-runtime`), no `default` (fail closed), for platform use only. Tenants never reference them. Namespaced ProviderConfigs are not shipped; per-subscription ones come from the Subscription composition (later PR).

## Bootstrap resource group

Create the three identities in a separate bootstrap resource group (`<BOOTSTRAP_RG>`), not in the central vended-UAMI resource group (`<IDENTITY_RG>`). Only platform admins have rights on the bootstrap RG. Identity-admin must not be able to modify its own or the other bootstrap identities.

## Roles

| Identity | Role assignments (document only; created by the admin) |
|---|---|
| vending (`<VENDING_CLIENT_ID>`) | Subscription creator at the invoice section only (MCA: `Azure subscription creator` on `<INVOICE_SECTION>`; EA: enrollment account subscription creator). On the single vending management group `<VENDING_MG>` only (never tenant root): write/read of subscriptions via a custom role, preferably the custom role, because Management Group Contributor also allows creating and deleting child management groups under `<VENDING_MG>`. No Owner, Contributor, role-assignment or resource-plane rights. |
| identity-admin (`<IDENTITY_ADMIN_CLIENT_ID>`) | Managed Identity Contributor on `<IDENTITY_RG>` only. RBAC Administrator (never User Access Administrator or Owner) at `<VENDING_MG>` with an ABAC condition limiting role assignment writes and deletes to role definition `<CONTRIBUTOR_ROLE_DEFINITION_ID>` (EnvironmentConfig `subscriptionRoleDefinitionId`) and principal type `ServicePrincipal`. |
| runtime (`<RUNTIME_CLIENT_ID>`) | No standing role beyond Reader on `<IDENTITY_RG>` if needed. Later scope needs (hub connection, IPAM pool) go through the Drizzt security gate as a narrow custom role at hub/pool scope. |
| per-subscription UAMI (created later) | Contributor on its own subscription (accepted exception E1). |

Vending management group association: the provider's `Subscription` managed resource (`azure.m.upbound.io`, v2.8.0) has no management group field (`forProvider`: `billingScopeId`, `subscriptionId`, `subscriptionName`, `tags`, `workload`). The association is therefore a separate `ManagementGroupSubscriptionAssociation`, so the vending identity keeps the management group permission above. Verified from the CRD; the Azure-side alias behaviour was not tested.

Vending MG hygiene and residual risk: `<VENDING_MG>` must contain only vended subscriptions. Identity-admin can grant Contributor to any service principal in those subscriptions (the ABAC condition cannot narrow it further). This is covered by accepted exceptions E1 and E3.

## Federated credentials

Issuer `<OIDC_ISSUER_URL>`, audience `api://AzureADTokenExchange`. Exactly one federated credential per bootstrap identity, one subject, no wildcards.

| Identity | Subject |
|---|---|
| runtime | `system:serviceaccount:crossplane-system:provider-azure` |
| identity-admin | `system:serviceaccount:crossplane-system:provider-azure-identity` |
| vending | `system:serviceaccount:crossplane-system:provider-azure` (shared subject, accepted exception E9) |
| per-subscription UAMI | one FIC trusting only the shared-tier subject (EnvironmentConfig key `providerServiceAccountSubject`) |

The identity-admin subject is never trusted by any UAMI or the runtime identity. The identity-admin tier subject is held only by the identity-admin identity.

Rotation: a cluster rebuild changes the OIDC issuer, so all federated credentials must be recreated.

## Accepted exception E9: vending shares the shared-tier subject

The vending identity trusts the shared subject because `Subscription` lives in `provider-family-azure`, which runs in the shared tier, so a separate vending tier cannot be selected per ClusterProviderConfig. Approval conditions:

- the vending identity has no resource-plane rights;
- it is bounded to the invoice section and the vending MG;
- M5 and M6 are mandatory before the first non-sandbox deployment;
- E9 expires together with E3.
- A compromised pod token in any shared-tier provider can act as vending, as the runtime identity and as every per-subscription UAMI.
- E9 ends if `Subscription` moves to a provider outside the shared family, or if a per-CPC runtime becomes possible.

## Runtime tiers

`setup/deployment-runtime-config.yaml` defines two DeploymentRuntimeConfigs. Each sets the pod label `azure.workload.identity/use: "true"` and a ServiceAccount named like the DRC. Every Provider in `setup/providers.yaml` sets an explicit `runtimeConfigRef`.

| DRC / ServiceAccount | Providers |
|---|---|
| `provider-azure` (shared) | provider-family-azure, storage, network, keyvault, containerapp, management |
| `provider-azure-identity` | provider-azure-managedidentity, provider-azure-authorization |

No `provider-azure-vending` runtime is shipped: no package is exclusive to the vending identity.

ServiceAccounts carry no client ID annotation; the client ID comes from the ClusterProviderConfig. This was not tested against a live cluster, so confirm during the first deployment that the workload identity webhook injects the token without an annotation. If it needs one, add a placeholder annotation. This is a first-deployment gate owned by Imoen, with a Drizzt re-check.

### CRD to package verification

Verified by exporting the pinned v2.8.0 xpkgs from `xpkg.upbound.io` (`crane export`, `package.yaml`) and listing the namespaced (`*.azure.m.upbound.io`) CRDs. All eight packages exist at v2.8.0.

| Package | Relevant kinds |
|---|---|
| provider-azure-managedidentity | UserAssignedIdentity, FederatedIdentityCredential |
| provider-azure-authorization | RoleAssignment, RoleDefinition, ManagementLock, policy and PIM kinds |
| provider-azure-management | ManagementGroup, ManagementGroupSubscriptionAssociation |
| provider-family-azure | ClusterProviderConfig, ProviderConfig, Subscription, ResourceGroup, ResourceProviderRegistration |
| storage, network, keyvault, containerapp | their own service kinds only (no identity or role kinds) |

Consequences:

- `ManagementLock` is in `authorization`. No composition or example may create a ManagementLock until a Drizzt-approved decision defines its identity and scope. A lock must not use platform-identity-admin, and per-subscription UAMIs must not trust the identity-tier subject. Contributor cannot write locks (to be verified at first deployment).
- `management` stays shared: its association kind is used with the vending identity, which can only authenticate from the shared tier (E9). The check that it needs no per-subscription kind passed, but moving it would break vending.
- `Subscription` is in provider-family-azure, so no package is exclusive to vending.

What was not verified: workload identity webhook behaviour in a live cluster, Azure-side role behaviour, and that the ABAC condition matches your Azure RBAC version.

First-deployment gates, owned by Imoen with a Drizzt re-check:

- the workload identity webhook injects the token without a client ID annotation;
- the ABAC condition syntax is valid at management-group scope for both write and delete;
- the Azure-side management-group association rights actually work.

## Custom roles for VirtualNetwork (E11)

The identity-admin identity creates these two custom roles and grants them to each per-subscription UAMI; no composition does. Role definition IDs are environment-specific and not listed here.

| Role | Actions | Scope |
|---|---|---|
| Hub connection manager | `Microsoft.Network/virtualHubs/hubVirtualNetworkConnections/read`, `.../write`, `.../delete` | the platform virtual hub |
| IPAM pool associator | `Microsoft.Network/ipamPools/associateResourcesToPool/action` | the IPAM pool |

Not Network Contributor, and never subscription-wide. Without them `VirtualNetwork` fails closed with a 403. See `docs/apis/virtualnetwork.md` for the blast radius.

Owner of E11 is Petter. It is open to veto.

## Unverified until the first sandbox deploy

None of these is proven outside `crossplane render` and `kind-cel.sh`. Verify each in the sandbox:

- The exact RBAC actions the provider needs for VirtualHubConnection and IPAM allocation. The action names above are a design assumption.
- The 403 fail-closed behaviour actually occurring when the two custom roles are absent.
- The hub route-table isolation design (E12).
- The CEL cost budget and the source-prefix regexes being accepted by a real API server, beyond what `kind-cel.sh` shows.
- The go-templating `ExtraResources` templated-namespace restriction, and Fatal retaining composed resources, on a live Crossplane.

## Install prerequisite: Crossplane RBAC for platform kinds

Crossplane's service account needs get/list/watch on the `platform.a5n.io` XR kinds and on every composed kind. Crossplane v2 aggregates ClusterRoles labelled `rbac.crossplane.io/aggregate-to-crossplane: "true"` into its own role. Without this the XR controllers cannot start watching. Untested outside kind.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-a5n-crossplane
  labels:
    rbac.crossplane.io/aggregate-to-crossplane: "true"
rules:
  - apiGroups: ["platform.a5n.io"]
    resources: ["subscriptions", "virtualnetworks"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["platform.a5n.io"]
    resources: ["subscriptions/status", "virtualnetworks/status"]
    verbs: ["get", "update", "patch"]
  - apiGroups:
      - network.azure.m.upbound.io
      - managedidentity.azure.m.upbound.io
      - authorization.azure.m.upbound.io
      - management.azure.m.upbound.io
      - azure.m.upbound.io
    resources: ["*"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```

Adjust the provider groups to the CRDs your compositions compose. Composed kinds in other groups need the same grant.
