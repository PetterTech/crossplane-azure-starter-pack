# ContainerApp

`ContainerApp` (`platform.a5n.io/v1alpha1`, namespaced) creates, in the namespace's Subscription:

**Read this first.** One resource is one container app in its own Container Apps environment (named `<app>-env`), running one public container image. Logs are not collected: the environment has no Log Analytics destination, so only the live log stream shows output, and troubleshooting a crashing app is expensive until the platform adds a log sink. Private apps have no private DNS zone group (see below), so until the platform provides DNS, clients inside the network can't resolve the app by name; that is a known limit, not a fault of your resource. The private endpoint must be in the same region as its subnet, so `location` must match the platform subnet's region. The image must come from a public registry: there are no registry credentials and no secrets in this API.

- a workload-profiles Container Apps environment with a Consumption profile, `publicNetworkAccess` Disabled unless `networking` is `public`;
- one container app (single revision, HTTPS only, one container, HTTP scale rule);
- a private endpoint (group `managedEnvironment`) in the platform subnet, only when `networking` is `private` (the default), the app has no `infrastructureSubnetId` of its own and the platform has a subnet. No private endpoint is ever created without a subnet.

There is no ManagementLock and no role assignment. Everything is tagged with `a5n-namespace`, `a5n-owner-xr` and `a5n-xr-uid`, plus `costCenter`, `owner` and `environment` from `spec`. Diagnostic settings are not part of the XR (see `docs/tenant-controls.md`).

## Example

See `projects/services/examples/containerapp/containerapp.yaml`.

## Which Subscription

The shared resolver (`projects/foundation/apis/_shared/resolver.md`) uses `spec.subscription`, or else the only Ready `Subscription` in the namespace, and pins it in `status`. Every managed resource uses the namespaced `ProviderConfig` named after that Subscription.

## Network modes

| `networking` | `infrastructureSubnetId` | Result |
| --- | --- | --- |
| `private` (default) | not set | environment with public access Disabled and a private endpoint in the platform subnet; ingress `internal` only |
| `private` | set | environment injected into your dedicated subnet; ingress `internal` gets an internal load balancer; no private endpoint |
| `public` | not set | environment with public access Enabled; `ingress: external` is allowed |
| `public` | set | injected environment with public access; `external` ingress is public |

Private endpoint and VNet injection can be combined in Azure, but this API keeps them exclusive. A private endpoint works only on a workload-profiles environment with public access Disabled, which is why a Consumption workload profile is always set (without it the environment is consumption-only: it needs a /23, has no delegation and no private endpoint).

The injected subnet is user-supplied and dedicated: at least /27, empty and delegated to `Microsoft.App/environments`. The platform does not create or delegate it. `networking`, `infrastructureSubnetId` and `zoneRedundant` are fixed at creation (CEL), as Azure fixes the environment's network when it is created. `zoneRedundant` requires `infrastructureSubnetId`.

## Pipeline

`environment-configs` -> `function-kro` (environment, app, conditional private endpoint; kro reads the pinned `status.environment` through an `externalRef` to the XR itself) -> `resolve-subscription` (shared resolver, inlined copy) -> `auto-ready`.

Reconcile 1 only pins the Subscription and the environment. From the second, the environment is created; the app and the private endpoint follow once the environment reports its ID.

## Environment keys

| Key | Use |
| --- | --- |
| `location`, `resourceGroupName` | where the resources go (pinned) |
| `subnetId` | the private endpoint subnet; required only for `networking: private` without `infrastructureSubnetId` (pinned) |
| `allowedLocations` | optional, comma separated; checked when the location is first pinned |

A private app without a valid platform `subnetId` (missing, placeholder or malformed) and without its own `infrastructureSubnetId` fails closed: the resolver result is Fatal with `SubnetNotConfigured` (visible in the `Synced` message), nothing is composed or pinned, and `Ready` is not reported (it would otherwise be True with nothing composed). It composes once the platform sets the subnet. A pinned app whose subnet later disappears from the environment keeps its endpoint and reports drift (`EnvironmentDrift`).

## Private DNS (known gap, D6)

The composition creates no private DNS zone group, because the EnvironmentConfig contract has no zone-ID key. Without a zone group the environment's default domain (`<name>.<region>.azurecontainerapps.io`) does not resolve to the private IP, and the public path is blocked: private apps are unreachable by name until an Azure Policy (DeployIfNotExists) for `privatelink.<region>.azurecontainerapps.io` or a future optional environment key supplies the zone group. `status.defaultDomain` and `status.fqdn` show the names to resolve.

## Deletion and adoption by name

`spec.deletionPolicy` is `Orphan` (default) or `Delete`, as for the Subscription (`managementPolicies` without `Delete`; `.m` MRs have no `deletionPolicy`). It applies to the environment and the app. The private endpoint carries no override and is removed with the resource either way.

- `Orphan`: deleting the resource leaves the app and its environment in Azure, still running and still billed. Nobody manages them afterwards.
- `Delete`: the app and the environment are deleted, including the app's revisions.
- Adoption by name: the derived names depend only on the namespace, the resource name and the Subscription. Re-creating a resource with the same name derives the same names and adopts an orphaned app and environment with their settings. Set `parameters.name` to pick another, or delete the leftovers first.

## Image rules

Public registries only. No private registry, no credentials, no secrets, no environment variables, no volumes. The tag must not be `latest` and a reference without a tag or digest is rejected (CEL); a digest (`@sha256:...`) is the preferred form. The tenant-side restriction to approved registries is a platform policy (see `docs/tenant-controls.md`).

## Hardening

| Setting | Value |
| --- | --- |
| Transport | HTTPS only: `allowInsecureConnections` false, no HTTP |
| Ingress | `internal` by default; `external` only with `networking: public` (CEL) |
| Environment network access | Disabled unless `networking: public` |
| Identity | `none` (default) or `system`; the principal ID is in `status.principalId`, no role is assigned (E1) |
| Revision mode | single |
| Size | `small` 0.25 CPU / 0.5Gi, `medium` 0.5 / 1Gi, `large` 1 / 2Gi |
| Replicas | `minReplicas` 0-10, `maxReplicas` 1-10, min <= max (CEL) |
| Workload profile | Consumption only |
| Logging | none: no Log Analytics destination |

## Naming

`spec.parameters.name` (2-32 lowercase letters, digits and single hyphens; starts with a letter, ends with a letter or digit) is the app name; the environment is `<name>-env`. It can only be set when the resource is created; adding, changing or removing it later is rejected (CEL), so an existing app is never swapped. Otherwise the app name is `ca` plus 22 characters from `random.seededString`, seeded on namespace, name and subscriptionId: deterministic, always 24 lowercase alphanumeric characters starting with a letter, different per Subscription and per resource name. The names are recorded in `status.appName` and `status.environmentName` (write-once) and the composition reads the pin first (pin, then `parameters.name`, then the derived name), so they never change even if the derivation changes.

## Status

`appName`, `environmentName`, `resourceId`, `environmentId`, `defaultDomain`, `fqdn`, `url` (`https://<fqdn>`), `principalId` (system identity only), `privateEndpointId` (private endpoint only), and the write-once pins (`subscription`, `subscriptionUid`, `subscriptionId`, `environment`, `appName`, `environmentName`).

## Schema deviations

- The private endpoint group ID is `managedEnvironment` (singular). The plan text said `managedEnvironments`.
- `infrastructureSubnetId` needs a /27 or larger subnet delegated to `Microsoft.App/environments` (the XRD said /23, which applies to consumption-only environments); a Consumption workload profile is always set.
- `status.environment` carries no `tenantId` (the XRD's draft had one) and gains `subnetId`; `status.appName` and `status.environmentName` are write-once.
- No log fields (`logsDestination`, `logAnalyticsWorkspaceId`): both are optional in Azure, and omitting them means no logs are stored.
- No private DNS zone group (see above); no role assignment (E1); no diagnostics in the XR (K1).
- Provider kind `Environment` (`containerapp.azure.m.upbound.io`) is Azure's managed environment. Numbers (`targetPort`, replicas) are passed as `double` because the provider schema type is number.

## Threat model

- The resolver is the trust boundary: it verifies the Subscription's UID and subscriptionId, and pins them (CEL write-once). A tenant cannot choose the region default, resource group default or the private endpoint subnet; they come from the EnvironmentConfig (the location only from the allowed list).
- Exposure: private by default; public requires an explicit `networking: public`, and an Internet-facing ingress additionally `ingress: external`. CEL rejects `external` with private. There is no IP allowlist in this API; an external app is open to the Internet.
- Supply chain: the image is the tenant's input. Public registries only, no `latest`, digest preferred; approved-registry enforcement is a platform policy, not this API.
- No secrets: no registry credentials, no environment variables and no secret store in the XR. A system identity has no role until the platform assigns one (E1).
- Cross-subscription network: the private endpoint joins the platform subnet, and an injected environment joins your dedicated subnet; both live outside the tenant Subscription (E13). The per-subscription identity needs the subnet-join rights on that subnet; without them the create fails closed with 403.
- Data loss: there is no ManagementLock, so deleting the XR with `deletionPolicy: Delete` deletes the app and its environment; `Orphan` leaves them running and unmanaged.
- Observability gap: no logs are stored, so abuse of an app (for example crypto mining) is visible only through Defender for Containers and cost anomalies.
- Fail closed: unresolved subscription, environment or location, and a private app without a subnet, are Fatal and stop composition.

## Unverified until the first sandbox deploy

- Subnet-join permission for the per-subscription identity on the platform subnet and on an injected subnet (fails with 403), E13.
- The private endpoint group ID `managedEnvironment` on a workload-profiles environment with public access Disabled, and the missing DNS zone group.
- Delegation and size of the injected subnet (/27, `Microsoft.App/environments`).
- That upjet creates the Consumption workload profile and accepts `publicNetworkAccess: Disabled` with `internalLoadBalancerEnabled` for the injected path.
- Zone redundancy behaviour on an injected environment.
- An absent `identity` block for `identity: none`, and the system identity's principal in `status.principalId` (only the composition was verified, on kind with hand-patched status).
- `httpScaleRule.concurrentRequests` as a string, and the `percentage` traffic weight as a number.
- Live behaviour of `Orphan` and `Delete` against a real provider (only the policy lists were verified, on kind).
- Stability of `random.seededString` across function-kro upgrades; a changed derivation would not move an existing app, because the names are pinned in `status`, but would change them for new ones.
- A Fatal result keeping the composed resources live (shown under render only).

## Tests

`projects/services/tests/containerapp/run.sh` renders every reconcile stage with `crossplane render`, validates the composed Environment, ContainerApp and PrivateEndpoint against the provider v2.8.0 CRDs (objects versus lists), and covers the private, public and injected modes, size and identity mapping, the fail-closed cases (no or ambiguous Subscription, not Ready, pin mismatch, missing or placeholder environment, private without subnet, location not allowed), the name derivation and pin order, and XRD CEL validation (ingress with private, zone redundancy without a subnet, replicas, image rules, name pattern and length). `kind-cel.sh` runs the write-once status and immutability rules, including adding a name or an infrastructure subnet, on a throwaway kind cluster.

`live.sh` installs Crossplane 2.4.3 and the pinned functions on a throwaway kind cluster with the provider CRDs only (no provider, no Azure) and checks the composed resources against the real CRDs, the name pins, a function-kro restart, the private, public and injected modes (separate resources, as `networking` is fixed), rejection of adding a name, `deletionPolicy` in both directions, and the fail-closed `SubnetNotConfigured` case, with the managed resources' status patched by hand. It proves composition behaviour, not anything in Azure.
