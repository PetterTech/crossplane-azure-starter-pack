# Local checks

These checks render every composition locally and validate the output against
schemas. They need no cluster and no Azure credentials, and they **do not test
live Azure behavior**: permissions, RBAC propagation, policy, DNS, routing and
deletion order are only exercised by a real deployment.

## Run all checks

With PowerShell 7, the Crossplane CLI and Docker running, run from the
repository root:

```shell
pwsh -NoProfile -File ./tests/test.ps1
```

The [test runner](test.ps1) runs with PowerShell 7 on Windows, Linux and macOS.
It renders all Space, Network, Bucket, SecretStore, App and LandingZone examples
plus ready-state fixtures, then validates examples and output against the XRDs,
pinned providers and Crossplane schemas.
Missing schemas and failed checks return a nonzero exit code.
Temporary output is removed; downloaded provider schemas and Docker images are cached.
Each run fetches the namespaced Usage CRD from the pinned Crossplane release on GitHub;
the first run also needs registry access.

The runner pins Crossplane `v2.4.3` for rendering. Keep it in sync with the
Helm chart version in [the deployment guide](../docs/deployment.md#2-install-crossplane).

Fixtures under `projects/<project>/tests/` use synthetic IDs, not a live tenant.
They stand in for EnvironmentConfig (`environment.yaml`) and for observed Azure
state (`observed-*.yaml`), so a render can show the complete resource graph.

## Render an API by hand

Run these from the repository root to see what a single composition produces.
Each section lists what the render does and does not prove.

### Space

```shell
crossplane render projects/foundation/examples/space-private.yaml \
  projects/foundation/apis/space/composition.yaml crossplane/functions.yaml \
  --crossplane-version=v2.4.3 \
  --xrd=projects/foundation/apis/space/definition.yaml \
  --required-resources=projects/foundation/tests/space/environment.yaml
```

Repeat with `space-public.yaml`. An initial render only creates the subscription
and identity. To render the completed composition, use
`projects/foundation/tests/space/xr-ready.yaml` as the XR and add
`--observed-resources=projects/foundation/tests/space/observed-ready.yaml`.
It should contain all five provider registrations and namespaced v2 Usages.

Validate the Space examples with:

```shell
crossplane resource validate projects/foundation/apis/space/definition.yaml \
  projects/foundation/examples/space-private.yaml,projects/foundation/examples/space-public.yaml
```

Validate rendered output against that XRD, the pinned provider CRDs and Crossplane's
Usage CRD. Rendering does not test Azure permissions, role propagation or deletion.

### Network

```shell
crossplane render projects/foundation/examples/network-private.yaml \
  projects/foundation/apis/network/composition.yaml crossplane/functions.yaml \
  --crossplane-version=v2.4.3 \
  --xrd=projects/foundation/apis/network/definition.yaml \
  --required-resources=projects/foundation/tests/network/environment.yaml \
  --observed-resources=projects/foundation/tests/network/observed-ready.yaml \
  --include-full-xr
```

Repeat with `network-public.yaml` and
`projects/foundation/tests/network/observed-public.yaml`.
The private graph includes the hub connection and dependency Usages. Validate examples
against the Network XRD, and full render output against that XRD, the pinned
provider CRDs and Crossplane's v2 Usage CRD.
Rendering does not verify Azure permissions, RBAC propagation, routing or deletion.

### Bucket

```shell
crossplane render projects/services/examples/bucket.yaml \
  projects/services/apis/bucket/composition.yaml crossplane/functions.yaml \
  --crossplane-version=v2.4.3 \
  --xrd=projects/services/apis/bucket/definition.yaml \
  --required-resources=projects/services/tests/bucket/environment.yaml \
  --observed-resources=projects/services/tests/bucket/observed-ready.yaml \
  --include-full-xr
```

Without `--observed-resources` only the Network Usage is created; the rest
follows once it is ready. The test runner also checks dependency failures and
container input limits. Rendering does not verify Azure permissions, DNS or
deletion.

### SecretStore

```shell
crossplane render projects/services/examples/secretstore.yaml \
  projects/services/apis/secretstore/composition.yaml \
  crossplane/functions.yaml \
  --crossplane-version=v2.4.3 \
  --xrd=projects/services/apis/secretstore/definition.yaml \
  --required-resources=projects/services/tests/secretstore/environment.yaml \
  --observed-resources=projects/services/tests/secretstore/observed-ready.yaml \
  --include-full-xr
```

Without `--observed-resources` only the Network Usage is created; the rest
follows once it is ready. The test runner also checks dependency failures.
Rendering does not verify Azure permissions, DNS, recovery or deletion.

### App

```shell
crossplane render projects/services/examples/app.yaml \
  projects/services/apis/app/composition.yaml crossplane/functions.yaml \
  --crossplane-version=v2.4.3 \
  --xrd=projects/services/apis/app/definition.yaml \
  --required-resources=projects/services/tests/app/environment.yaml \
  --observed-resources=projects/services/tests/app/observed-ready.yaml \
  --include-full-xr
```

Without observations only the Network Usage is created. The test runner covers
staged creation, public/private graphs, dependency failures, input limits and
runtime/status outputs. It validates against the pinned provider CRDs and XRD.
These checks do not verify Azure connectivity, DNS, identity grants, image pulls,
autoscaling, deletion or update-time immutability enforcement.

### LandingZone

```shell
crossplane render projects/stacks/examples/landingzone-private.yaml \
  projects/stacks/apis/landingzone/composition.yaml crossplane/functions.yaml \
  --crossplane-version=v2.4.3 \
  --xrd=projects/stacks/apis/landingzone/definition.yaml \
  --observed-resources=projects/stacks/tests/landingzone/observed-ready.yaml \
  --include-full-xr
```

Without observations only Space is created. The test runner covers staged
creation, defaults and overrides, missing outputs, readiness regression,
dependency Usages and input limits. It also renders the emitted child XRs
against their compositions and validates the output. These local checks do
not verify API-server ownership conflicts, update-time immutability, actual
deletion order, private DNS or Azure behavior.
