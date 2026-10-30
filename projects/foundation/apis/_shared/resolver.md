# Shared resolver (accepted exception E6)

`resolver.gotmpl` is the one go-templating step allowed in a building block (`resolve-subscription`). It sits after function-kro in the pipeline and before auto-ready. Packages cannot share files, so every building-block composition carries an identical inlined copy. `sync-resolver.sh <composition.yaml>...` writes the copy between the `# BEGIN resolver` and `# END resolver` markers, and `scripts/validate.sh` fails when a copy differs from this file. Edit `resolver.gotmpl`, then sync; never edit a copy.

## What it does

1. Asks Crossplane for every `platform.a5n.io/v1alpha1` `Subscription` in the XR's namespace (go-templating `ExtraResources` with a templated namespace; no label selector, so the whole namespace is listed). The first call of a reconcile returns only that requirement.
2. Resolves the Subscription: the pinned `status.subscription`, else `spec.subscription`, else the only Ready Subscription in the namespace.
3. Pins `status.subscription`, `status.subscriptionUid` and `status.subscriptionId` (write-once, enforced by the XRD) and verifies the pin on every reconcile.
4. Resolves and pins `status.environment` (`location`, `resourceGroupName`, and per kind the extra keys below) from `spec.parameters` overrides and the EnvironmentConfig, checks the keys the kind needs, and reports drift.
5. Sets the conditions `SubscriptionResolved`, `EnvironmentValid` and `EnvironmentDrift`.

Every composed resource uses the namespaced `ProviderConfig` named after the resolved Subscription (`status.subscription`).

## Fail closed

Every unresolved path calls `fail`, which makes the function result Fatal: nothing is applied or deleted, `Synced` becomes `False` with the reason as message prefix, and function-auto-ready is never reached (with no composed resources it would report Ready).

| Prefix | When |
| --- | --- |
| `SubscriptionNotFound` | no Subscription in the namespace |
| `SubscriptionAmbiguous` | several Ready Subscriptions and no `spec.subscription` |
| `SubscriptionNotReady` | the chosen Subscription is not Ready or has no `status.subscriptionId` |
| `SubscriptionMismatch` | `spec.subscription` differs from the pin |
| `SubscriptionChanged` | the pinned Subscription is gone, was recreated (uid differs), its subscriptionId differs, or the pin is incomplete |
| `EnvironmentInvalid` | a key the kind needs is missing, a `<PLACEHOLDER>`, or malformed |
| `SubnetNotConfigured` | StorageAccount, KeyVault and ContainerApp only: `networking` private, no valid `subnetId` and nothing pinned yet (a ContainerApp with its own `infrastructureSubnetId` needs no platform subnet) |
| `InfrastructureSubnetNotAllowed` | ContainerApp only: `infrastructureSubnetId` equals the platform `subnetId` (case-insensitive, live or pinned). Every per-subscription identity holds the subnet-join role on the platform subnet (E13), so a tenant must not be able to inject an environment into it |
| `LocationNotAllowed` | the location is not in the EnvironmentConfig `allowedLocations` (checked once, when the location is first pinned) |

Because a custom condition set next to a Fatal result is shown as Unknown, these failures are visible in the `Synced` message, not as `False` conditions.

`HubNotConfigured` (`peerToHub` true, no usable `hubVirtualHubId`) is the one non-fatal case: `EnvironmentValid` is `False` and the hub connection is not composed.

## Handing the environment to function-kro

function-kro cannot read the environment context. The resolver therefore also writes the values kro needs into `status.environment` (`ipamPoolId`, and `hubVirtualHubId` when the platform has a hub, both from the EnvironmentConfig on first use; once `status.environment` exists it is re-emitted unchanged, because the XRD makes it write-once as a whole object), and kro reads them through an `externalRef` to the XR itself. Nothing is composed on the first reconcile, because the pin does not exist yet.

`StorageAccount` (in `projects/services`, which carries its own inline copy; `validate.sh` checks every `projects/*/apis/*/composition.yaml` against this one file) adds `subnetId` to `status.environment`. The live value is used only when it is a well-formed subnet resource ID; a missing, placeholder or malformed value counts as absent. `SubnetNotConfigured` is Fatal when `networking` is private, there is no valid subnet and nothing is pinned yet: nothing is composed or pinned and `Ready` is not reported (see `Synced`). For an account already pinned without a subnet (public, later flipped to private) it is non-fatal: `EnvironmentValid=False` and no endpoint. Once pinned the value is re-emitted unchanged and drift is reported. `KeyVault` follows the same `subnetId` rules and also pins `tenantId` (required, must be a GUID; a missing, placeholder or malformed value is `EnvironmentInvalid`; a pinned vault keeps its tenant and reports drift). `ContainerApp` follows the same `subnetId` rules (the platform subnet is the endpoint subnet of a private environment) but only when it has no `infrastructureSubnetId` of its own: a VNet-injected app uses its own subnet, so a missing platform subnet is not an error for it. It pins no `tenantId`. It also fails with `InfrastructureSubnetNotAllowed` (Fatal) when `infrastructureSubnetId` equals the platform `subnetId`, compared case-insensitively against the live and the pinned value.

## Adding a building block

Add a row to the per-kind key table (`$required`) for the EnvironmentConfig keys the block uses, copy the step from an existing composition, run `sync-resolver.sh`, and declare any new `status.environment` key in the XRD.
