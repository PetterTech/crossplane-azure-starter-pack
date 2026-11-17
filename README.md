# crossplane-azure-starter-pack

A starting point for building an internal platform on Azure with Crossplane.

This is an accelerator, not a product. Fork it, read it, change it. Nothing here is production ready as-is, and it is meant to be simple enough that you understand all of it before you use any of it.

The landing zone follows the same model as Microsoft's Azure Landing Zones and subscription vending, so it should feel familiar if you know CAF, and give you a CAF-aligned starting point if you don't.

## What you get

A small set of Kubernetes APIs that platform teams install and application teams use. One `LandingZone` in a team's namespace gives that team a subscription, a network, blob storage and a Key Vault, without anyone filing a ticket.

```text
crossplane/            Providers, functions and runtime config to install into the cluster
projects/foundation/   Space and network: the building blocks of a landing zone
projects/services/     Single resources teams use inside their landing zone
projects/stacks/       APIs that combine other APIs, like LandingZone
docs/                  Deployment guide and API reference
tests/                 Local render and schema checks
```

Each project is a Crossplane CLI project with its own `crossplane-project.yaml`, an `apis/` folder with one XRD and composition per API, and `examples/`.

| Layer | API | What it is |
| --- | --- | --- |
| foundation | `Space` | A subscription in the corp or online management group, with its own identity |
| foundation | `Network` | An IPAM-allocated VNet, connected to the hub for private Spaces |
| services | `Bucket` | Blob storage (storage account) |
| services | `SecretStore` | A private Key Vault |
| services | `App` | One container image on Azure Container Apps |
| stacks | `LandingZone` | A `Space`, `Network`, `Bucket` and `SecretStore` in one go |

Stacks only combine other APIs. Services build on foundation. Details for each API, including what deleting it does, are in [docs/apis.md](docs/apis.md).

## How it works

**Composition.** Every API is a Crossplane v2 XRD with a Pipeline composition. Compositions only use standard functions (environment-configs, patch-and-transform, kro, go-templating, sequencer, auto-ready). There are no custom functions. Platform settings such as tenant, region, management groups, IPAM pool and hub live in one `EnvironmentConfig`, not in the compositions.

**Identity.** Crossplane authenticates with Workload Identity, no secrets. A central platform identity only does bootstrap work: creating the subscription, a dedicated managed identity per Space, its access, and hub connections. Everything inside a Space's subscription is then created with that Space's own identity, through a ProviderConfig in the team's namespace. Teams never pick credentials.

## What you need

More than a cluster. The starter pack plugs into an existing Azure Landing Zones style platform:

- An AKS cluster (or another cluster with a public OIDC issuer) you can install Crossplane into.
- A billing account where a service principal may create subscriptions (EA or MCA).
- Corp and online management groups.
- A resource group for Space identities.
- An Azure Virtual Network Manager IPAM pool and a Virtual WAN hub.
- Private DNS zones for blob storage and Key Vault, with policy or automation that adds private endpoint records.
- Rights to grant roles on all of the above.

The [deployment guide](docs/deployment.md#before-you-start) has the full checklist, including exactly which roles go where.

## Getting started

[Deploy your first LandingZone](docs/deployment.md) walks through it on AKS:

1. Install Crossplane.
2. Turn on Workload Identity and create the platform identity.
3. Grant it access to billing, management groups, the IPAM pool and the hub.
4. Install the providers and functions.
5. Fill in the ClusterProviderConfig and EnvironmentConfig templates.
6. Install the foundation, services and stacks APIs, in that order.
7. Create a namespace and apply the private LandingZone example.
8. Verify it in Kubernetes and Azure, then clean up.

## Local checks

With PowerShell 7, the Crossplane CLI and Docker running, run from the repository root:

```shell
pwsh -NoProfile -File ./tests/test.ps1
```

This renders every example and validates the output against the XRDs and pinned provider schemas. It needs no cluster or Azure credentials. See [tests/README.md](tests/README.md) for what it covers and how to render a single API by hand.

## Status and limitations

**Tested:** local rendering and schema validation only.
**Not yet verified:** a live deployment to Azure. Permissions, policy, DNS, routing and deletion order are untested until someone runs the deployment guide against a real tenant.

Know these before you rely on it:

- **Shared provider identity.** All provider pods run as one Kubernetes service account that every Space identity trusts. Namespaces do not isolate Azure identities. Only platform controllers should be able to write ProviderConfigs, managed resources or XR status.
- **Bucket has a public endpoint.** The provider needs data-plane access to the storage account, so public network access stays on (Entra ID only, no shared keys). Azure Landing Zones policies that deny public network access will block it, and the cluster must be able to reach the blob endpoint.
- **Private DNS is not created here.** Bucket, SecretStore and private Apps rely on Azure Policy or your own automation to add private endpoint DNS records.
- **App has no private outbound connectivity.** Its private endpoint is inbound only, so an App can't reach private Bucket or SecretStore endpoints yet.
- **Exposure is governance, not networking.** `private` and `public` on Space and LandingZone choose the corp or online management group. They don't make anything reachable from or hidden from the internet. Only App's exposure changes network access.
- **Deletion is real.** Deleting a LandingZone deletes the Bucket's data and is meant to cancel the subscription. Cancellation through the provider hasn't been verified yet, so check the subscription state afterwards. See [Clean up](docs/deployment.md#12-clean-up).

## Before you use this for real

- Replace `platform.example.org` with your own domain and fill in the platform templates.
- Think through identity: which identity each team gets, and what it is allowed to do.
- Lock down what teams can create. Teams should only get access to your platform APIs, not to provider resources or ProviderConfigs.
- Decide how Bucket fits your public network access policy before teams start using it.

## Documentation

- [Deploy your first LandingZone](docs/deployment.md)
- [API reference](docs/apis.md)
- [Local checks](tests/README.md)

## License

MIT
