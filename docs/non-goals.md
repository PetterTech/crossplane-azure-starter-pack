# Non-Goals

This repository is a starter pack and reference implementation. It is not production-ready as-is.

## Out of scope in the current iteration

- Flux or Argo CD setup
- Helm packaging
- CI/CD pipelines
- Backstage integration
- full production RBAC model
- policy engine integration
- complex test frameworks

## Decisions left to platform adopters

Production usage requires explicit decisions for:

- authentication and identity model
- provider config lifecycle
- subscription vending
- management group placement
- Azure Policy
- RBAC
- multi-tenancy
- GitOps
- observability
- secret management
- testing and validation
- naming and tagging standards
- IPAM integration and network governance

## Intent

The goal is to provide a reusable baseline that teams can adapt, not a complete production platform blueprint.
