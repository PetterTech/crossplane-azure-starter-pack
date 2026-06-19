# Bootstrap Assumptions

This starter pack assumes a greenfield CAF-aligned Azure environment already exists.

The platform team is assumed to have access to bootstrap values such as:

- tenant ID
- management group IDs
- subscription vending configuration
- default Azure region
- naming prefix
- default tags
- DNS and connectivity details
- hub or routing values where needed

These values belong in platform-admin configuration, not in developer-facing resource specs.

This first pass includes placeholder admin manifests to make those inputs visible without pretending they are complete.
