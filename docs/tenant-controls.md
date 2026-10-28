# Tenant controls

These are documented prerequisites, not shipped RBAC. Apply them in the cluster that runs the platform.

- Only platform principals hold write verbs (create, update, patch, delete) on `Provider`, `DeploymentRuntimeConfig`, `ProviderConfig`, `ClusterProviderConfig`, `EnvironmentConfig`, `Subscription` XRs, raw managed resources, `Usage`, and any `*/status` subresource.
- In `crossplane-system`, only platform principals can create or update pods, use `pods/exec`, create `serviceaccounts/token`, or read secrets. Anyone with these can obtain a provider pod token and act as every identity that trusts its ServiceAccount (see `docs/identity-bootstrap.md`).
- Tenants cannot create namespaces.
- Tenants never reference `ClusterProviderConfig` objects; compositions always set the provider config reference explicitly, and there is no `default` ClusterProviderConfig.
