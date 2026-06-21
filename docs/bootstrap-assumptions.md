# Bootstrap Assumptions

This starter pack assumes a greenfield CAF-aligned Azure environment already exists.

The platform team is assumed to provide bootstrap values through platform-admin configuration, for example:

- <tenant-id>
- <management-group-id>
- <billing-scope>
- <default-location>
- <central-identity-subscription-id>
- <central-identity-resource-group-name>
- <central-identity-location>
- <vwan-hub-id>
- <connectivity-subscription-id>
- naming and tagging defaults
- network governance and IPAM defaults

The central identity resource group referenced by platform defaults is assumed
to already exist and be managed by platform administration.

These values belong in platform-admin configuration, not in developer-facing resource specs.

The manifests in examples/platform-admin are examples with placeholders, not environment-specific defaults.
