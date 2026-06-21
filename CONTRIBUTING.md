# Contributing

Thanks for your interest in improving this starter pack.

This repository is a community-friendly reference implementation for building developer-friendly Azure platform APIs with Crossplane. Contributions are welcome.

## Good contribution areas

- additional Azure resources and compositions
- better and clearer examples
- documentation improvements
- validation and testing improvements
- production-hardening notes
- alternative implementation patterns that preserve the public API contract

## Public API contract guidance

Public APIs are the user-facing contract:

- LandingZone -> XLandingZone
- Network -> XNetwork
- Storage -> XStorage

Please treat public API changes carefully. Breaking or expanding public fields should include:

- a clear rationale
- migration notes
- updates to examples and docs

Internal Azure APIs can evolve faster as long as they do not leak Azure implementation details into public APIs.

## Architecture expectations

- Keep developer-facing APIs cloud-agnostic.
- Keep Azure-specific logic in internal Azure composites and compositions.
- Prefer patch-and-transform.
- Use Go templating only where patch-and-transform is insufficient.

## Before opening a PR

- Confirm examples still run as expected.
- Update related docs when behavior changes.
- Keep placeholders explicit when implementation details are intentionally incomplete.
- Keep comments and TODOs contributor-friendly and specific.

## Scope note

This project is starter-pack quality and not production-ready as-is. Improvements that make this clearer and easier to adapt are especially valuable.
