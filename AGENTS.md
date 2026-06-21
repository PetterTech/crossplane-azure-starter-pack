# AGENTS.md

## Project purpose

This repository is a Crossplane Azure starter pack for demonstrating how a platform team can expose developer-friendly platform products on top of Azure.

The primary goal is to show clean, cloud-agnostic, developer-facing APIs backed by Crossplane compositions and Azure implementation details.

This is a learning-focused starter pack and reference implementation. Prefer clarity, readability, and educational value over production completeness.

## Core design principles

### Developer APIs describe intent

Developer-facing APIs must describe what the developer needs, not how Azure should implement it.

Good examples:

* `LandingZone`
* `Network`
* `Storage`
* `environment`
* `type`
* `size`
* `owner`
* `tags`

Avoid exposing Azure-specific concepts in developer-facing APIs, such as:

* subscription ID
* tenant ID
* resource group name
* Azure region
* vWAN hub ID
* route table ID
* providerConfigRef
* CIDR blocks
* Azure resource names
* Azure-specific SKU names, unless no abstraction exists yet

### Public APIs should be cloud-agnostic

The public API group should represent platform products, not Azure resources.

Crossplane terminology in this repo:

* Developer-facing claims are defined using `claimNames` on public platform XRDs.
* Public platform products must keep claim and composite kinds separate:
  * namespaced claim kind for developers
  * cluster-scoped composite kind for Crossplane
* Do not collapse claim and composite resource into one kind for public APIs.

Use public APIs such as:

* `platform.example.org/v1alpha1`
* Claim kinds: `LandingZone`, `Network`, `Storage`
* Composite kinds: `XLandingZone`, `XNetwork`, `XStorage`

Azure-specific implementation details belong in internal APIs such as:

* `azure.platform.example.org/v1alpha1`
* `XAzureLandingZone`
* `XAzureVirtualNetwork`
* `XAzureStorageAccount`

Internal Azure XRDs are composite-only implementation contracts and must not define `claimNames`.

The design should allow Azure to be replaced or supplemented by another implementation later, such as AWS or GCP, without changing the developer-facing API shape.

### Layered composition model

Use a layered model:

1. Developer-facing claim
2. Public platform composite resource
3. Public platform composition
4. Function/selector logic where needed
5. Cloud-specific internal composite resource
6. Cloud-specific compositions
7. Azure managed resources

Example:

```text
Network claim
  -> XNetwork
  -> XNetwork composition
  -> Go templating decision step if needed
  -> XAzureVirtualNetwork
  -> corp or online Azure composition
  -> Azure managed resources
```

### Patch-and-transform first

Use declarative patch-and-transform compositions by default.

If the goal requires more functionality than patch-and-transform can provide, use Go templating.

Go templating is acceptable for small decision layers, such as:

* reading a referenced `LandingZone`
* deriving network profile from landing zone type
* emitting an internal cloud-specific XR
* selecting between internal compositions

Do not use Go templating for everything by default.

Avoid introducing other composition technologies such as KCL, CUE, Python functions, or custom Go functions unless explicitly requested.

### Keep developer input minimal

Developer-facing claims should require as little input as possible.

The developer should not need Azure knowledge to create platform products.

For example, a developer should be able to create a landing zone with:

```yaml
apiVersion: platform.example.org/v1alpha1
kind: LandingZone
metadata:
  name: payments-dev
spec:
  application: payments
  environment: dev
  type: corp
  owner:
    team: payments
```

And a network with:

```yaml
apiVersion: platform.example.org/v1alpha1
kind: Network
metadata:
  name: payments
spec:
  landingZoneRef:
    name: payments-dev
  size: small
```

### No developer-provided IP ranges

Developers must not provide CIDR blocks or address spaces.

Network claims may describe intent or size, for example:

```yaml
spec:
  size: small
```

The Azure implementation may assume Azure native IPAM is available. Internal Azure resources may supply the CIDR notation needed for Azure IPAM to allocate address space, but that must not leak into the public API.

### Landing zones own scope

A `LandingZone` should represent the main platform scope for an application or team environment.

For this starter pack, assume a greenfield CAF-aligned Azure setup exists and that subscription vending is in scope.

The landing zone should be responsible for creating or preparing:

* Azure subscription
* landing-zone-specific identity
* role assignments
* landing-zone-specific provider configuration
* useful status fields for later products

A key convention:

```text
The ProviderConfig created for a LandingZone should have the same name as the LandingZone.
```

Later products can then patch:

```text
spec.landingZoneRef.name -> spec.providerConfigRef.name
```

### Child products reference landing zones

Products such as `Network` and `Storage` should reference a landing zone by name.

Example:

```yaml
spec:
  landingZoneRef:
    name: payments-dev
```

They should not ask the developer to repeat values already known by the landing zone, such as whether the landing zone is `corp` or `online`.

If a child product needs information from the landing zone, use a small Go templating step to read the referenced landing zone and derive the required internal implementation fields.

### Network profile should be derived

A landing zone may have a public field like:

```yaml
spec:
  type: corp
```

The platform should derive internal implementation details from that, such as:

```yaml
status:
  networkProfile: corp
```

The `Network` product should not ask the developer to repeat the type.

The user-facing `Network` composition may read the referenced landing zone and emit an internal Azure network XR with a composition selector such as:

```yaml
compositionSelector:
  matchLabels:
    platform.example.org/network-profile: corp
```

### Keep products small and composable

Products should be small building blocks.

A landing zone should not automatically include a network unless explicitly modeled that way.

A developer may claim:

* one landing zone
* one or more networks
* one or more storage products
* later, other managed resources

Products should be able to build on each other through references.

### Repository audience

This repository has two audiences:

1. Developers and application teams

   * They should see simple YAML claims first.
   * They should understand the platform product model without needing Azure knowledge.

2. Platform engineers

   * They should be able to inspect XRDs, compositions, provider configs, patching, function steps, and Azure managed resources.

The README should introduce the developer-facing API first, then explain the implementation layers.

### Repository structure

Use this structure unless there is a strong reason to change it:

```text
crossplane-azure-starter-pack/
├── README.md
├── AGENTS.md
├── docs/
│   ├── architecture.md
│   ├── product-model.md
│   ├── bootstrap-assumptions.md
│   ├── api-design.md
│   ├── demo-flow.md
│   └── decisions.md
├── platform/
│   ├── provider-configs/
│   │   └── provider-config.yaml
│   ├── functions/
│   │   └── function-go-templating.yaml
│   └── apis/
│       ├── landingzone/
│       │   ├── xrd.yaml
│       │   ├── composition.yaml
│       │   └── examples/
│       │       ├── landing-zone-corp.yaml
│       │       └── landing-zone-online.yaml
│       ├── network/
│       │   ├── xrd.yaml
│       │   ├── composition.yaml
│       │   └── examples/
│       │       ├── network-corp.yaml
│       │       └── network-online.yaml
│       ├── storage/
│       │   ├── xrd.yaml
│       │   ├── composition.yaml
│       │   └── examples/
│       │       └── storage.yaml
│       └── azure/
│           ├── xazurelanding-zone/
│           │   ├── xrd.yaml
│           │   └── composition.yaml
│           ├── xazurevirtual-network/
│           │   ├── xrd.yaml
│           │   ├── composition-corp.yaml
│           │   └── composition-online.yaml
│           └── xazurestorage-account/
│               ├── xrd.yaml
│               └── composition.yaml
└── examples/
    ├── claims/
    │   ├── 01-landing-zone-corp.yaml
    │   ├── 02-network-corp.yaml
    │   ├── 03-landing-zone-online.yaml
    │   ├── 04-network-online.yaml
    │   └── 05-storage.yaml
    └── platform-admin/
        ├── provider-config.yaml
        └── platform-config.yaml
```

Do not add scripts unless explicitly requested. The user already has a separate way to spin up AKS with Crossplane installed.

### Initial platform products

Start with these public claim kinds:

1. `LandingZone`
2. `Network`
3. `Storage`

Back those claims with these public composite kinds:

1. `XLandingZone`
2. `XNetwork`
3. `XStorage`

Start with these internal Azure implementation products:

1. `XAzureLandingZone`
2. `XAzureVirtualNetwork`
3. `XAzureStorageAccount`

Storage may initially be a minimal product backed by Azure Storage Account.

### Azure assumptions

Assume a greenfield CAF-aligned Azure environment already exists.

Assume the platform has access to required bootstrap values, such as:

* tenant ID
* billing or subscription vending details
* management group IDs
* vWAN hub details
* default region
* naming prefix
* default tags
* DNS/platform connectivity details

These values belong in platform/admin configuration, not developer-facing claims.

### Provider choice

Use the Upjet-based Azure Crossplane provider family.

Do not use Azure Service Operator in this repo unless explicitly requested.

Do not use Terraform provider as the primary implementation path.

### Starter-pack walkthrough scope

This repository should be easy to run with:

```bash
kubectl apply -f examples/claims/01-landing-zone-corp.yaml
kubectl apply -f examples/claims/02-network-corp.yaml
kubectl apply -f examples/claims/05-storage.yaml
```

The walkthrough should show:

* the clean developer claim
* the generated public platform composite XR
* the generated internal Azure XR
* selected composition
* Azure managed resources

### Out of scope for now

Do not add the following unless explicitly requested:

* Flux
* Argo CD
* Helm charts
* CI/CD pipelines
* multi-namespace tenancy model
* production RBAC model
* policy engine integration
* Backstage integration
* real enterprise IPAM integration
* full CAF deployment
* AKS workload platform
* advanced observability
* complete production security hardening

### Documentation expectations

When adding a new product, include:

* public XRD
* internal Azure XRD where needed
* composition
* example claim
* short explanation in docs
* notes on what is starter-scope-only
* notes on what would need hardening for production

### Style

Prefer simple, readable YAML.

Prefer explicit naming over clever abstraction.

Use comments where they help explain the platform pattern.

Avoid pretending starter-pack placeholders are production-ready. Mark uncertain or simplified areas with clear TODO comments.

When unsure, optimize for teaching the platform pattern.

Every enum should have a default value to minimize required developer input.
