# AGENTS.md

This repo is an accelerator for Crossplane v2 on Azure. Readers should be able to understand every file. Simple and readable beats complete and clever.

## Layout

- `crossplane/` - providers, functions, DeploymentRuntimeConfig
- `projects/<project>/` - Crossplane CLI project: `crossplane-project.yaml`, `apis/<api>/definition.yaml` + `composition.yaml`, `examples/`
- `foundation` - landing zone building blocks (`Space`, `Network`)
- `services` - single resources teams use inside a landing zone (`Bucket`, `SecretStore`, `App`)
- `stacks` - APIs that only combine other APIs (`LandingZone`)

## Rules

- Crossplane v2 only: `apiextensions.crossplane.io/v2` XRDs, namespaced XRs, Pipeline mode, namespaced managed resources (`*.m.upbound.io`).
- Stacks compose XRs only, never managed resources. If an API creates Azure resources itself, it belongs in foundation or services.
- Stacks may depend on foundation and services. Services may depend on foundation. Foundation must not depend on either services or stacks.
- Keep the landing zone aligned with Azure Landing Zones subscription vending.
- Functions, in order of preference: patch-and-transform, then function-kro, then go-templating. Use the first one that can do the job cleanly. function-sequencer handles ordering, auto-ready goes last. Do not write custom functions or add new languages, scripts or build steps.
- Every composition must clean up after itself. If a resource depends on another, use function-sequencer with `enableDeletionSequencing: true` and `usageVersion: v2` so Usages delete things in the right order. No orphaned Azure resources after an XR is deleted.
- Exception: subscriptions are never deleted by Crossplane. Leave out `Delete` in `managementPolicies` and say so in the `Space` XRD description.
- Each composition must be readable on its own. No shared templates copied between compositions.
- Prefer one obvious way. Do not add auto-discovery, fallbacks or options nobody asked for.
- Name APIs after what the user wants, not the Azure resource behind it (`Bucket`, not `StorageAccount`).
- Avoid kinds that already exist in a typical cluster: `Service`, `Application`, `Project`, `Environment`, `Tenant` and the Upbound managed resource kinds.
- Validate input in the XRD schema (enum, min/max, CEL), not in the composition.
- XRDs must not expose `providerConfigRef`, `providerConfigName`, `providerConfigKind` or `compositionRef` to users.
- No secrets, tenant IDs, subscription IDs or client IDs hardcoded in compositions. Use EnvironmentConfig.
- Pin every provider and function to an exact, current and supported version.
- Keep documentation short, concise and focused on the essentials. Cut the fluff.
- Markdown should pass markdownlint or a similar linter.

## Identity model

- Workload Identity only (`credentials.source: OIDCTokenFile`). No client secrets.
- The `ClusterProviderConfig` is the platform's identity. Only foundation may use it.
- Each `Space` gets its own subscription and managed identity, with a role only on that subscription, and a namespaced ProviderConfig in the team's namespace. Services always use that ProviderConfig.

## Checking your work

- `crossplane render` each example against its composition and functions.
- `crossplane resource validate` the rendered output against the provider CRDs and the XRD.
- Say what you actually ran. Do not claim something works against Azure unless it was tested there.
