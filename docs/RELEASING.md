# Releasing

Each project (`foundation`, `services`, `landingzone`) is released independently as a Crossplane Configuration package at
`ghcr.io/pettertech/crossplane-azure-starter-pack/<project>:<version>`. The workflow is `.github/workflows/release.yaml`.

## Versioning policy

- Independent semver per project. Tags are `foundation/vX.Y.Z`, `services/vX.Y.Z`, `landingzone/vX.Y.Z`. No pre-release suffixes: the workflow rejects them.
- Bump rules: removing a field (for example `providerConfig*`) or a breaking XRD change is a major bump; a new optional field is minor; a composition fix is patch.
- While a project is 0.x, a minor bump may be breaking and ranges are `>=v0.x.y <v0.(x+1).0`. From 1.0 they are `>=vA.B.C <v(A+1).0.0`. `scripts/check-release-ranges.sh` rejects other range shapes.
- Published versions are immutable. The workflow refuses to push a version that already exists; fix forward with a new patch.
- A project is re-released only if it changed, or if a dependency range no longer matches (for example foundation went to `v0.2.0`: landingzone must raise its range in `projects/landingzone/crossplane-project.yaml` and be released again). The ranges script warns about this when you release a dependency.
- Provider and function pins in `crossplane-project.yaml` are exact. Renovate proposes bumps; a pin change is a project change and needs a release to reach users.

## Order (bottom-up)

1. `foundation` and `services` (independent of each other; either order).
2. `landingzone`, only after versions inside its ranges are published. The preflight fails with the tag to create first if one is missing.

## Pre-release function-kro pin (E7)

function-kro is pre-1.0 and pinned exactly (`v0.3.0`). Before every release, check upstream function-kro releases and its input API changes. A new version is adopted only through a Renovate PR with render and validate evidence; never bump it in the release commit. Record the pin in the release notes.

## Release steps

1. Merge everything to `main`; CI (`ci-ok`) must be green. Update dependency ranges first if a dependency is being re-released.
2. Locally on `main`, up to date: `BUILD=0 scripts/validate.sh` and `scripts/check-release-ranges.sh <project> vX.Y.Z` (this uses git tags; the workflow additionally checks ghcr.io).
3. Tag and push, one project at a time, and wait for the `release` run to succeed before the next:
   ```sh
   git tag foundation/v0.1.0 && git push origin foundation/v0.1.0
   git tag services/v0.1.0   && git push origin services/v0.1.0
   git tag landingzone/v0.1.0 && git push origin landingzone/v0.1.0
   ```
4. The `preflight` job checks the tag name, that the tag is on `main`, that the version is not yet published, `scripts/validate.sh`, the ranges and order, and the project's `run.sh` tests. Only then `publish` builds and pushes with crossplane CLI v2.5.0 (the only job with `packages: write`, using `GITHUB_TOKEN`).
5. Make new packages pullable: the first push creates a private package. In GitHub package settings set visibility to public and link the repository (unverified, see below).
6. After foundation and services are published, enable the landingzone build in CI: repository Settings, Secrets and variables, Actions, Variables, add `LANDINGZONE_BUILD` = `true`. Until then ci.yaml only runs landingzone render tests.
7. To re-run a failed release: Actions, `release`, Run workflow, enter the existing tag. Nothing is pushed if the version already exists.

## Rollback

Published packages are immutable and consumers pin ranges, so do not delete them.

- Bad release: fix on `main` and release the next patch. Consumers on a range pick it up.
- Withdraw a version: delete that package version in GitHub package settings and delete the git tag (`git push origin :refs/tags/<project>/vX.Y.Z`, then `git tag -d`). Never re-push the same version after consumers may have pulled it.
- A bad foundation or services release that landingzone already depends on: release the fixed patch, then re-release landingzone only if its range excludes it.

## Not done / unverified

- The release workflow has never run; nothing has been published. The first run is the test: expect to adjust it.
- `crossplane project build/push` flags (`--repository`, `--tag`) were checked against CLI v2.5.0 help only. Whether `project push --tag` also pushes embedded function packages and tags them the same is unverified.
- `docker buildx imagetools inspect` as the published-check works anonymously only for public packages; the workflow logs in with `GITHUB_TOKEN` (`packages: read`), which may not read an unlinked private package.
- Package visibility and repository linking are manual in GitHub settings.
- Signing and provenance (cosign keyless, build attestations) are not enabled. Follow-up: add `id-token: write` and `attestations: write` to the publish job only, with a pinned `actions/attest-build-provenance` step, once the first release works.
- The `LANDINGZONE_BUILD` switch and path-filter interaction with tag pushes are untested in Actions.
- Version availability is derived from git tags plus the registry; there is no in-repo version file, so `landingzone` ranges are checked against released tags, not against unreleased in-repo changes.
