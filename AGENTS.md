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

## API design

- Keep public inputs small and user-facing. Expose intent, not provider configuration or platform plumbing.
- Keep platform settings and additional platform-owned tags in EnvironmentConfig. Merge tags so platform-owned values take precedence.
- Space exposes displayName, exposure (`private` or `public`) and tags. Exposure selects the platform-configured corp or online management group.
- Services select a Space by name in their namespace. Resolve its ProviderConfig explicitly; no auto-discovery or user-supplied credentials.

## Lifecycle

- Delete resources owned by an API when its XR is deleted, unless retention is explicitly required.
- For retained resources, omit `Delete` from managementPolicies and document what remains in Azure in the XRD description.
- Subscriptions may be deleted. Management-group associations and resource-provider registrations must not be deleted or unregistered by Crossplane.
- Sequence dependent resources using function-sequencer with `enableDeletionSequencing: true` and `usageVersion: v2`. Preserve credentials and access until dependent cleanup completes.

## Identity model

- Workload Identity only (`credentials.source: OIDCTokenFile`). No client secrets.
- Use the central platform identity only for bootstrap operations that require platform-level access. Only foundation may use its ClusterProviderConfig.
- Each Space gets a dedicated managed identity in the central Azure identity resource group, with Owner scoped only to its subscription.
- Bootstrap creates the subscription, identity, federation, role assignment and namespaced ProviderConfig. Subsequent operations use the Space identity wherever Azure permissions allow.
- Keep each Space's ProviderConfig in the Space/team namespace. Services use the selected Space's ProviderConfig, never the platform identity.
- Hub connections are a platform operation and use the ClusterProviderConfig.
  Space identities never get access to the hub.

## Checking your work

- `crossplane render` each example against its composition and functions.
- `crossplane resource validate` the rendered output against the provider CRDs and the XRD.
- Say what you actually ran. Do not claim something works against Azure unless it was tested there.

## Commits and PRs

- Use conventional commits for commit messages.
- Use atomic commits: each commit should do one thing and be self-contained.
- Pull request descriptions should clearly explain what the PR does and why.
- Link to relevant issues or discussions when applicable.
