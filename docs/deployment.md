# Deploy your first LandingZone

This guide takes you from an AKS cluster to one running
[private LandingZone](../projects/stacks/examples/landingzone-private.yaml):
a subscription in your corp management group with its own identity, a
hub-connected network, a Bucket and a SecretStore.

> [!IMPORTANT]
> This walkthrough has **not yet been run end to end against Azure**. The
> compositions pass local render and schema checks, nothing more. Expect to
> adjust things on your first deployment, and read
> [Troubleshooting](#11-troubleshooting) before you start.

All commands use **bash** (Linux, macOS, WSL or Azure Cloud Shell) and run from
the repository root. Later steps reuse variables set in earlier ones, so keep
the same terminal open.

## Before you start

### Tools and cluster

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), signed in
  with `az login`.
- `kubectl`, [Helm](https://helm.sh/docs/intro/install/) v3.2 or later and `git`.
- Optional: the [Crossplane CLI](https://docs.crossplane.io/latest/cli/) for
  `crossplane resource trace`.
- An AKS cluster on a supported Kubernetes version, with cluster-admin access,
  and permission to update the cluster (to turn on OIDC and Workload Identity).
- Outbound access from the cluster to the package registries
  (`xpkg.crossplane.io`, `xpkg.upbound.io`), Azure Resource Manager, Microsoft
  Entra ID and the blob endpoints of the storage accounts it creates.

### Azure infrastructure that must already exist

The starter pack plugs into an existing Azure Landing Zones style platform. It
does not create any of this:

| What | Why | Goes into |
| --- | --- | --- |
| Billing account with an EA enrollment account or MCA invoice section | New subscriptions are billed here | `billingScopeID` |
| Corp and online management groups | Private Spaces go in corp, public in online | `managementGroupIds` |
| A subscription with a resource group for identities | Every Space's managed identity is created here | ClusterProviderConfig `subscriptionID`, `identityResourceGroupName` |
| Azure Virtual Network Manager IPAM pool with free space | Each Network takes a `/25` to `/23` from it | `ipamPoolID` |
| Virtual WAN hub | Networks in private Spaces connect to it | `virtualHubID` |
| Private DNS zones `privatelink.blob.core.windows.net` and `privatelink.vaultcore.azure.net`, plus the policy or automation that adds records for new private endpoints | Bucket and SecretStore private endpoints need DNS | Not configured here |

Check the policies on your corp management group. The Azure Landing Zones
policy that denies public network access on storage accounts **blocks Bucket**,
because Bucket keeps its public endpoint so the provider can reach the data
plane. You need an exemption for these subscriptions or the LandingZone will
never get past Bucket. See [Bucket](apis.md#bucket).

### Permissions

You, the person running this guide, need to:

- Update the AKS cluster and create a managed identity next to it.
- Assign Azure roles at every scope in [step 4](#4-grant-the-platform-identity-access)
  (Owner, User Access Administrator or Role Based Access Control Administrator there).
- Grant a service principal permission to create subscriptions in your billing
  account (EA enrollment account owner or MCA invoice section owner).

The platform identity you create in step 3 ends up with:

| Role | Scope | Used for |
| --- | --- | --- |
| Subscription creator (billing role) | Enrollment account or invoice section | Creating subscriptions |
| Managed Identity Contributor | Central identity resource group | Creating Space identities and federation |
| Management Group Contributor | Corp and online management groups | Placing subscriptions |
| Role Based Access Control Administrator, conditioned to IPAM Pool User | IPAM pool | Letting Space identities use the pool |
| Network Contributor | Hub resource group | Hub connections |

When a service principal creates a subscription through the subscription alias
API, Azure makes it Owner of that subscription. The starter pack relies on this
to give the Space identity Owner and, later, to cancel the subscription.

You never grant anything to Space identities yourself. Each one gets **Owner**
on its own subscription and **IPAM Pool User** on the pool, created by Crossplane.

### What the starter pack creates

For the `development` LandingZone in namespace `team-a`:

| Created by Crossplane | Where |
| --- | --- |
| Subscription, placed in the corp management group | Billing scope |
| Space managed identity, its federated credential, Owner and IPAM Pool User assignments | Central identity resource group |
| Namespaced ProviderConfig `development` | Kubernetes namespace `team-a` |
| Resource provider registrations | New subscription |
| Resource group `network-development` with VNet, subnet and NSG | New subscription |
| Network Contributor on the VNet for the platform identity, and the hub connection | VNet and hub |
| Resource group `bucket-development` with storage account, container `default` and private endpoint | New subscription |
| Resource group `secretstore-development` with Key Vault and private endpoint | New subscription |

Everything in [the infrastructure table](#azure-infrastructure-that-must-already-exist)
stays yours: Crossplane never creates or deletes the pool, hub, management
groups, DNS zones or the identity resource group.

These resources cost money. A subscription, a hub connection and two private
endpoints are billed while they exist.

## 1. Get the repository

Fork the repository if you plan to change it, then clone it:

```bash
git clone https://github.com/PetterTech/crossplane-azure-starter-pack.git
cd crossplane-azure-starter-pack
```

Set the values you will reuse. Replace every `<...>` placeholder:

```bash
# AKS cluster
AKS_SUBSCRIPTION_ID=<aks-subscription-id>
AKS_RG=<aks-resource-group>
AKS_NAME=<aks-cluster-name>

# Subscription and resource group where Space identities are created
IDENTITY_SUBSCRIPTION_ID=<identity-subscription-id>
IDENTITY_RG=<identity-resource-group>

# Management group names (not full IDs)
CORP_MG=<corp-management-group-name>
ONLINE_MG=<online-management-group-name>

# Networking
IPAM_POOL_ID=/subscriptions/<pool-subscription-id>/resourceGroups/<pool-rg>/providers/Microsoft.Network/networkManagers/<manager-name>/ipamPools/<pool-name>
HUB_SUBSCRIPTION_ID=<hub-subscription-id>
HUB_RG=<hub-resource-group>
HUB_NAME=<virtual-hub-name>
```

Connect `kubectl` to the cluster:

```bash
az account set --subscription "$AKS_SUBSCRIPTION_ID"
az aks get-credentials -g "$AKS_RG" -n "$AKS_NAME"
kubectl get nodes
```

## 2. Install Crossplane

Install Crossplane with Helm, using the version the repository pins. See the
[official install guide](https://docs.crossplane.io/latest/get-started/install/)
for options.

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace \
  --version 2.4.3
```

Wait until Crossplane is running and its APIs exist:

```bash
kubectl wait deployment/crossplane deployment/crossplane-rbac-manager \
  -n crossplane-system --for=condition=Available --timeout=5m
kubectl wait --for=condition=Established --timeout=2m \
  crd/deploymentruntimeconfigs.pkg.crossplane.io \
  crd/environmentconfigs.apiextensions.crossplane.io \
  crd/usages.protection.crossplane.io
```

The local checks render against the same version. If you change it here, change
`$crossplaneVersion` in [tests/test.ps1](../tests/test.ps1) too.

## 3. Turn on Workload Identity and create the platform identity

Crossplane talks to Azure with Workload Identity: a managed identity that trusts
the providers' Kubernetes service account. No secrets.

Do this **before** installing providers. The Workload Identity webhook only
changes pods created after it is turned on.

```bash
az aks update -g "$AKS_RG" -n "$AKS_NAME" --enable-oidc-issuer --enable-workload-identity
ISSUER=$(az aks show -g "$AKS_RG" -n "$AKS_NAME" --query oidcIssuerProfile.issuerUrl -o tsv)

az identity create -g "$AKS_RG" -n crossplane
az identity federated-credential create -g "$AKS_RG" --identity-name crossplane \
  --name provider-azure \
  --issuer "$ISSUER" \
  --subject system:serviceaccount:crossplane-system:provider-azure \
  --audience api://AzureADTokenExchange

PLATFORM_CLIENT_ID=$(az identity show -g "$AKS_RG" -n crossplane --query clientId -o tsv)
PLATFORM_PRINCIPAL_ID=$(az identity show -g "$AKS_RG" -n crossplane --query principalId -o tsv)
TENANT_ID=$(az identity show -g "$AKS_RG" -n crossplane --query tenantId -o tsv)
echo "$ISSUER $PLATFORM_CLIENT_ID $PLATFORM_PRINCIPAL_ID $TENANT_ID"
```

The service account name `provider-azure` is set in
[deployment-runtime-config.yaml](../crossplane/deployment-runtime-config.yaml)
and in the [Space composition](../projects/foundation/apis/space/composition.yaml),
which federates every Space identity with the same subject. Keep all three in sync.

Not on AKS? Any cluster with a public OIDC issuer works the same way. See
[Workload identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation).

## 4. Grant the platform identity access

The central identity resource group must exist. Create it if needed:

```bash
az group create -g "$IDENTITY_RG" -l <azure-region> --subscription "$IDENTITY_SUBSCRIPTION_ID"
```

Grant the Azure roles:

```bash
az role assignment create --assignee-object-id "$PLATFORM_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Managed Identity Contributor" \
  --scope "/subscriptions/$IDENTITY_SUBSCRIPTION_ID/resourceGroups/$IDENTITY_RG"

for mg in "$CORP_MG" "$ONLINE_MG"; do
  az role assignment create --assignee-object-id "$PLATFORM_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Management Group Contributor" \
    --scope "/providers/Microsoft.Management/managementGroups/$mg"
done

az role assignment create --assignee-object-id "$PLATFORM_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope "/subscriptions/$HUB_SUBSCRIPTION_ID/resourceGroups/$HUB_RG"
```

You can grant Management Group Contributor on a shared ancestor instead of both
groups. New subscriptions start in your tenant's default management group. If
that is not the tenant root group, the identity also needs Management Group
Contributor there to move them out.

For the pool, use a [delegation condition][delegation-conditions] that restricts
both creation and deletion to IPAM Pool User. Crossplane needs delete access to
remove a Space's pool assignment when that Space is deleted.

```bash
az role assignment create --assignee-object-id "$PLATFORM_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Role Based Access Control Administrator" \
  --scope "$IPAM_POOL_ID" \
  --condition "(
    (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
    )
    OR
    (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId]
      ForAnyOfAnyValues:GuidEquals {7b3e853f-ad5d-4fb5-a7b8-56a3581c7037}
    )
  )
  AND
  (
    (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
    )
    OR
    (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId]
      ForAnyOfAnyValues:GuidEquals {7b3e853f-ad5d-4fb5-a7b8-56a3581c7037}
    )
  )" \
  --condition-version 2.0
```

[delegation-conditions]: https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-overview#how-to-delegate-role-assignment-management-with-conditions

Finally, let the identity create subscriptions. This is a billing role, not an
Azure RBAC role, so `az role assignment` can't do it. Use the principal ID from
step 3 and follow
[Assign roles to EA service principals](https://learn.microsoft.com/azure/cost-management-billing/manage/assign-roles-azure-service-principals)
(enrollment account subscription creator) or, for MCA, give it the Azure
subscription creator role on the invoice section. Background:
[Create subscriptions programmatically](https://learn.microsoft.com/azure/cost-management-billing/manage/programmatically-create-subscription).

Check the RBAC assignments. Each scope should print one role:

```bash
for scope in \
  "/subscriptions/$IDENTITY_SUBSCRIPTION_ID/resourceGroups/$IDENTITY_RG" \
  "/providers/Microsoft.Management/managementGroups/$CORP_MG" \
  "/providers/Microsoft.Management/managementGroups/$ONLINE_MG" \
  "$IPAM_POOL_ID" \
  "/subscriptions/$HUB_SUBSCRIPTION_ID/resourceGroups/$HUB_RG"; do
  az role assignment list --assignee "$PLATFORM_PRINCIPAL_ID" --scope "$scope" \
    --query "[].{role:roleDefinitionName, scope:scope}" -o tsv
done
```

Role assignments can take several minutes to take effect. Crossplane retries,
so early permission errors are not necessarily a problem.

## 5. Install runtime config, providers and functions

Apply the three files explicitly. Don't apply `crossplane/` recursively: the
`templates/` folder holds placeholders that must be filled in first.

```bash
kubectl apply -f crossplane/deployment-runtime-config.yaml
kubectl apply -f crossplane/providers.yaml
kubectl apply -f crossplane/functions.yaml
```

Wait until every package is installed and healthy. Pulling eight providers can
take several minutes:

```bash
kubectl wait providers.pkg.crossplane.io --all --for=condition=Healthy --timeout=15m
kubectl wait functions.pkg.crossplane.io --all --for=condition=Healthy --timeout=10m
kubectl get providers.pkg.crossplane.io,functions.pkg.crossplane.io
```

Check that Workload Identity reached the provider pods. You should see one line
per provider, each with service account `provider-azure` and a token file path:

```bash
kubectl get pods -n crossplane-system -l azure.workload.identity/use=true \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\t"}{.spec.containers[0].env[?(@.name=="AZURE_FEDERATED_TOKEN_FILE")].value}{"\n"}{end}'
```

Wait for the provider config CRDs used in the next step:

```bash
kubectl wait --for=condition=Established --timeout=5m \
  crd/clusterproviderconfigs.azure.m.upbound.io \
  crd/providerconfigs.azure.m.upbound.io
```

The providers ship many more resource types than this pack uses. The comment in
[providers.yaml](../crossplane/providers.yaml) explains how to activate fewer.

## 6. Configure the platform

Two templates hold every tenant-specific value. Copy them out of the repository
so your IDs don't end up in a public fork:

```bash
PLATFORM_CONFIG=~/crossplane-platform-config
mkdir -p "$PLATFORM_CONFIG"
cp crossplane/templates/cluster-provider-config.yaml crossplane/templates/environment-config.yaml "$PLATFORM_CONFIG/"
```

Fill in `cluster-provider-config.yaml`. This is the platform identity, used only
for bootstrap and hub connections:

| Field | Value |
| --- | --- |
| `clientID` | `$PLATFORM_CLIENT_ID` (the client ID, not the principal ID) |
| `tenantID` | `$TENANT_ID` |
| `subscriptionID` | `$IDENTITY_SUBSCRIPTION_ID`, the subscription that holds `$IDENTITY_RG` |

Fill in `environment-config.yaml`:

| Field | Value |
| --- | --- |
| `tenantID` | `$TENANT_ID` |
| `oidcIssuerURL` | `$ISSUER`, exactly as printed, including any trailing slash |
| `defaultLocation` | Region for platform resources, for example `swedencentral` |
| `identityResourceGroupName` | `$IDENTITY_RG` |
| `billingScopeID` | EA: `/providers/Microsoft.Billing/billingAccounts/<account>/enrollmentAccounts/<enrollment-account>`; MCA: `/providers/Microsoft.Billing/billingAccounts/<account>/billingProfiles/<profile>/invoiceSections/<section>` |
| `managementGroupIds.corp` / `.online` | Full IDs: `/providers/Microsoft.Management/managementGroups/<name>` |
| `platformTags` | Optional. Up to 10 tags with lowercase keys; they override team tags |
| `platformPrincipalID` | `$PLATFORM_PRINCIPAL_ID` |
| `ipamPoolID` | `$IPAM_POOL_ID` |
| `virtualHubID` | `/subscriptions/$HUB_SUBSCRIPTION_ID/resourceGroups/$HUB_RG/providers/Microsoft.Network/virtualHubs/$HUB_NAME` |

Make sure no placeholders are left (this should print nothing), then apply:

```bash
grep -n '<' "$PLATFORM_CONFIG"/*.yaml
kubectl apply -f "$PLATFORM_CONFIG/cluster-provider-config.yaml"
kubectl apply -f "$PLATFORM_CONFIG/environment-config.yaml"
kubectl get clusterproviderconfigs.azure.m.upbound.io default
kubectl get environmentconfig azure -o yaml
```

Nothing validates these values yet. Mistakes show up as errors on the first
LandingZone, so double-check them now.

## 7. Install the APIs

Apply only the `apis/<api>/` folders, in dependency order. Never apply a
`projects/<project>/` folder recursively: it also contains examples and test
fixtures.

```bash
kubectl apply -f projects/foundation/apis/space -f projects/foundation/apis/network
kubectl wait xrd spaces.platform.example.org networks.platform.example.org \
  --for=condition=Established --timeout=5m

kubectl apply -f projects/services/apis/bucket -f projects/services/apis/secretstore \
  -f projects/services/apis/app
kubectl wait xrd buckets.platform.example.org secretstores.platform.example.org \
  apps.platform.example.org --for=condition=Established --timeout=5m

kubectl apply -f projects/stacks/apis/landingzone
kubectl wait xrd landingzones.platform.example.org --for=condition=Established --timeout=5m

kubectl get xrd
kubectl get compositions
```

App isn't part of a LandingZone. Installing it is harmless, but you can skip it.

## 8. Deploy the LandingZone

Look at the [example](../projects/stacks/examples/landingzone-private.yaml)
first. `displayName` becomes the subscription name and `tags` go on everything.
`exposure: private` places the subscription in corp and connects the network to
the hub. Exposure can't be changed later.

```bash
kubectl create namespace team-a
kubectl apply -f projects/stacks/examples/landingzone-private.yaml
```

Don't also apply the foundation or services examples into `team-a`. The
LandingZone creates a Space, Network, Bucket and SecretStore named `development`,
and [space-private.yaml](../projects/foundation/examples/space-private.yaml)
uses the same name.

In real use, teams should only get access to the platform APIs in their
namespace, not to providers, ProviderConfigs or managed resources.

## 9. Watch it come up

The LandingZone creates its children in order: Space, then Network, then Bucket
and SecretStore in parallel. Subscription creation alone takes minutes, so give
it time.

```bash
kubectl get landingzone development -n team-a
kubectl get space,network,bucket,secretstore -n team-a
crossplane resource trace landingzone development -n team-a
```

`crossplane resource trace` shows the whole tree with each resource's status.
Older CLI releases call it `crossplane beta trace`.

Read the conditions when something stays `READY=False`:

```bash
kubectl get landingzone development -n team-a \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
kubectl describe space development -n team-a
kubectl get managed -n team-a
```

`Ready=False` with a list of unready resources is normal while Azure works.
`Synced=False` means a composition or provider call failed; the message says
why. Look at the child that is not ready, then at its managed resources.

Wait for the whole thing:

```bash
kubectl wait landingzone/development -n team-a --for=condition=Ready --timeout=60m
```

When it's ready, the LandingZone publishes what teams need:

```bash
kubectl get landingzone development -n team-a -o jsonpath='{.status}'; echo
```

You should see `spaceName`, `networkName`, `subscriptionID`, `subnetID`,
`accountName`, `blobEndpoint`, `vaultName` and `vaultURI`. The Space's
credentials live in the namespaced ProviderConfig:

```bash
kubectl get providerconfigs.azure.m.upbound.io -n team-a
```

## 10. Verify in Azure

Kubernetes saying `Ready` means the provider saw the resources. Check Azure
directly too. You need read access to the new subscription, for example Reader
inherited from the corp management group.

Capture the published values. You need them again for cleanup:

```bash
SUBSCRIPTION_ID=$(kubectl get landingzone development -n team-a -o jsonpath='{.status.subscriptionID}')
ACCOUNT_NAME=$(kubectl get landingzone development -n team-a -o jsonpath='{.status.accountName}')
VAULT_NAME=$(kubectl get landingzone development -n team-a -o jsonpath='{.status.vaultName}')
SPACE_IDENTITY_ID=$(kubectl get space development -n team-a -o jsonpath='{.status.identity.resourceID}')
SPACE_PRINCIPAL_ID=$(kubectl get space development -n team-a -o jsonpath='{.status.identity.principalID}')
echo "$SUBSCRIPTION_ID $ACCOUNT_NAME $VAULT_NAME $SPACE_IDENTITY_ID"
```

Subscription and governance:

```bash
az account management-group subscription show --name "$CORP_MG" --subscription "$SUBSCRIPTION_ID"
az provider list --subscription "$SUBSCRIPTION_ID" \
  --query "[?contains(['Microsoft.Network','Microsoft.Storage','Microsoft.KeyVault','Microsoft.Compute','Microsoft.App'], namespace)].{namespace:namespace, state:registrationState}" -o table
```

Space identity, federation and access. Expect a credential named
`crossplane-provider` with subject
`system:serviceaccount:crossplane-system:provider-azure`, Owner on the
subscription and IPAM Pool User on the pool:

```bash
az identity federated-credential list -g "$IDENTITY_RG" --subscription "$IDENTITY_SUBSCRIPTION_ID" \
  --identity-name "${SPACE_IDENTITY_ID##*/}" --query "[].{name:name, issuer:issuer, subject:subject}" -o table
az role assignment list --assignee "$SPACE_PRINCIPAL_ID" --scope "/subscriptions/$SUBSCRIPTION_ID" -o table
az role assignment list --assignee "$SPACE_PRINCIPAL_ID" --scope "$IPAM_POOL_ID" -o table
```

Network and hub connection:

```bash
az network vnet show -g network-development -n network --subscription "$SUBSCRIPTION_ID" \
  --query "{addressSpace:addressSpace.addressPrefixes, subnets:subnets[].name}"
az network vhub connection list -g "$HUB_RG" --vhub-name "$HUB_NAME" --subscription "$HUB_SUBSCRIPTION_ID" \
  --query "[].{name:name, vnet:remoteVirtualNetwork.id, state:provisioningState}" -o table
```

Bucket and SecretStore. Expect ZRS, public network access `Enabled` with shared
keys off for the storage account, and public access `Disabled` with RBAC and
purge protection on for the vault:

```bash
az storage account show -n "$ACCOUNT_NAME" -g bucket-development --subscription "$SUBSCRIPTION_ID" \
  --query "{sku:sku.name, publicNetworkAccess:publicNetworkAccess, sharedKeyAccess:allowSharedKeyAccess}"
az storage container-rm list --storage-account "$ACCOUNT_NAME" -g bucket-development \
  --subscription "$SUBSCRIPTION_ID" --query "[].name" -o tsv
az keyvault show -n "$VAULT_NAME" -g secretstore-development --subscription "$SUBSCRIPTION_ID" \
  --query "{publicNetworkAccess:properties.publicNetworkAccess, rbac:properties.enableRbacAuthorization, purgeProtection:properties.enablePurgeProtection}"
```

Private DNS. Each endpoint should have a DNS zone group once your policy or
automation has run. An empty list means no DNS record yet:

```bash
az network private-endpoint dns-zone-group list --endpoint-name "${ACCOUNT_NAME}-blob" \
  -g bucket-development --subscription "$SUBSCRIPTION_ID" -o table
az network private-endpoint dns-zone-group list --endpoint-name "${VAULT_NAME}-vault" \
  -g secretstore-development --subscription "$SUBSCRIPTION_ID" -o table
```

## 11. Troubleshooting

Start with `crossplane resource trace` or `kubectl describe` on the resource
that isn't ready, then its managed resources. Events and provider logs carry
the Azure error:

```bash
kubectl get events -n team-a --sort-by=.lastTimestamp
kubectl get pods -n crossplane-system
kubectl logs -n crossplane-system <provider-pod-name>
kubectl logs -n crossplane-system deployment/crossplane
```

| Symptom | Likely cause |
| --- | --- |
| Provider or function never becomes `Healthy` | The cluster can't reach the package registry. Check `kubectl describe providers.pkg.crossplane.io <name>`. |
| Provider pods have no `AZURE_FEDERATED_TOKEN_FILE` | Workload Identity was turned on after the pods started. Delete the pods so their deployments recreate them. |
| `AADSTS700213` or `AADSTS70021`: no matching federated identity record | Issuer or subject mismatch. Compare `az identity federated-credential list` with `$ISSUER` and the `provider-azure` service account. For Space identities, check `oidcIssuerURL`. |
| `EnvironmentConfig azure requires <field>` | That field is missing or empty in the EnvironmentConfig. |
| Subscription stays unready with an authorization or billing error | The billing role is missing, or `billingScopeID` points at the wrong scope. |
| Management group association fails | Management Group Contributor is missing on the target group, or on the default management group if it isn't the tenant root. |
| Role assignment fails right after the subscription appears | RBAC propagation. Wait; Crossplane retries. |
| Network VNet fails | The pool is full, or the Space identity's IPAM Pool User assignment is missing. Check the platform identity's conditional role on the pool. |
| `RequestDisallowedByPolicy` | An Azure Policy denied the request. The message names the assignment. Bucket's public endpoint and subnets created without an NSG are likely candidates under Azure Landing Zones policies. |
| Hub connection fails with an authorization error | Network Contributor is missing on the hub resource group, or the VNet grant for the platform identity hasn't propagated yet. |
| `waiting for Network ... and Space ... to publish status` | Normal while dependencies come up. If it persists, look at the Network or Space. |
| Bucket fails on data-plane calls (403, timeouts on `*.blob.core.windows.net`) | The cluster can't reach the blob endpoint. If it resolves the private DNS zone, it needs a route to the private endpoint. |
| Private endpoint has no DNS zone group | DNS policy hasn't run, or isn't assigned to this management group. Remediate it or add records yourself. |

## 12. Clean up

> [!WARNING]
> Deleting a LandingZone is destructive and only partly reversible:
>
> - The **Bucket's storage account and all its data are deleted**. Blob soft
>   delete does not help once the account is gone.
> - The **subscription is meant to be cancelled**. The Space composition deletes
>   its Subscription resource, which should cancel it in Azure. It then becomes
>   `Disabled`, and Azure deletes it after a retention period. Cancellation
>   through the provider **has not been verified yet**, so check the
>   subscription state afterwards (see below). See
>   [Cancel and delete your Azure subscription](https://learn.microsoft.com/azure/cost-management-billing/manage/cancel-azure-subscription).
> - The Key Vault is soft-deleted with purge protection. It stays recoverable,
>   can't be purged, and its name stays reserved for 90 days. Recovery doesn't
>   restore role assignments.
> - The Space identity, its role assignments, the network, hub connection and
>   ProviderConfig are removed.

Crossplane intentionally leaves some things behind:

- The subscription's management-group association and resource provider
  registrations. They go away with the subscription.
- The soft-deleted vault, until its retention ends.
- Anything not created by Crossplane, such as resources deployed by Azure Policy
  or by hand.
- The platform itself: Crossplane, providers, the platform identity, its role
  assignments and your EnvironmentConfig.

Delete the **LandingZone**, never its children. The children are owned by the
LandingZone and will be recreated, and Usages block deleting a Space or Network
while something still depends on it. Don't delete the namespace either; that
removes everything at once and skips the ordering.

Make sure the variables from [step 10](#10-verify-in-azure) are still set, then
delete with foreground cascading deletion so services are cleaned up before the
network and the Space identity:

```bash
kubectl delete landingzone development -n team-a --cascade=foreground
```

The command waits until deletion finishes. Follow progress from another terminal:

```bash
crossplane resource trace landingzone development -n team-a
kubectl get space,network,bucket,secretstore -n team-a
```

Cleanup is done when Kubernetes has nothing left in the namespace:

```bash
kubectl get landingzone,space,network,bucket,secretstore -n team-a
kubectl get managed -n team-a
kubectl get usages.protection.crossplane.io -n team-a
kubectl get providerconfigs.azure.m.upbound.io -n team-a
```

And Azure agrees:

```bash
az rest --method get --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID?api-version=2022-12-01" \
  --query state -o tsv   # expect Disabled
az identity show --ids "$SPACE_IDENTITY_ID"   # expect ResourceNotFound
az keyvault list-deleted --resource-type vault \
  --query "[?name=='$VAULT_NAME'].{name:name, purgeDate:properties.scheduledPurgeDate}" -o table
az network vhub connection list -g "$HUB_RG" --vhub-name "$HUB_NAME" --subscription "$HUB_SUBSCRIPTION_ID" -o table
```

The hub connection to the deleted VNet should be gone.

If Kubernetes is clean but the subscription is still `Enabled`, cancellation
didn't work. Nothing in the cluster tracks the subscription anymore, so it keeps
running and costing money until you cancel it yourself, as described in the
Microsoft article linked above. Please report it as an issue too.

After that, `kubectl delete namespace team-a` is safe.

If deletion gets stuck, find the resource that isn't going away with
`crossplane resource trace`, read its conditions and events, and fix the cause:
usually a missing permission or an Azure-side lock or policy. **Don't remove
finalizers** to make it go away. That skips the cleanup Crossplane was waiting
for and leaves resources, possibly including a billed subscription, behind in
Azure with nothing tracking them.
