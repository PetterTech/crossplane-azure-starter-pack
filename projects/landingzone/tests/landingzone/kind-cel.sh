#!/usr/bin/env bash
# CEL tests for the LandingZone XRD that crossplane render can't run: status write-once
# (oldSelf rules), spec immutability, mutual exclusion and the Delete/DevTest rule. The XRD
# schema is turned into a plain CRD (no Crossplane) and applied to a throwaway kind cluster
# that is deleted afterwards. Only the kind context is used. Needs kind, kubectl, ruby, Docker.
set -euo pipefail

cd "$(dirname "$0")/../.."
CLUSTER=${CLUSTER:-pr13-cel}
CTX=kind-$CLUSTER
WORK=tests/landingzone/.work-kind
mkdir -p "$WORK"
cleanup() { kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

kind create cluster --name "$CLUSTER" --wait 120s >/dev/null
k() { kubectl --context "$CTX" "$@"; }

ruby -ryaml -e '
  x = YAML.load_file("apis/landingzone/definition.yaml")
  v = x["spec"]["versions"][0]
  crd = { "apiVersion" => "apiextensions.k8s.io/v1", "kind" => "CustomResourceDefinition",
    "metadata" => { "name" => "landingzones.platform.a5n.io" },
    "spec" => { "group" => "platform.a5n.io", "scope" => "Namespaced",
      "names" => { "kind" => "LandingZone", "plural" => "landingzones" },
      "versions" => [{ "name" => "v1alpha1", "served" => true, "storage" => true,
        "subresources" => { "status" => {} }, "schema" => v["schema"] }] } }
  File.write(ARGV[0], crd.to_yaml)' "$WORK/crd.yaml"
k apply -f "$WORK/crd.yaml" >/dev/null
k wait --for=condition=Established crd/landingzones.platform.a5n.io --timeout=60s >/dev/null
k create namespace t >/dev/null

expect_ok() {
  local n=$1; shift
  if out=$("$@" 2>&1); then echo "PASS $n"; else echo "FAIL $n: $out"; exit 1; fi
}
expect_reject() {
  local n=$1 pat=$2; shift 2
  if out=$("$@" 2>&1); then echo "FAIL $n: accepted"; exit 1; fi
  if grep -q "$pat" <<<"$out"; then echo "PASS $n"; else echo "FAIL $n: $out"; exit 1; fi
}

SUBNET=/subscriptions/cccccccc-1111-2222-3333-dddddddddddd/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet
# mk <name> [spec body as YAML, indented two spaces]
mk() {
  k -n t apply -f - >/dev/null <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: LandingZone
metadata:
  name: $1
spec:
${2:-  {\}}
EOF
}
dry() { # name spec-yaml
  k -n t apply --dry-run=server -f - <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: LandingZone
metadata:
  name: $1
spec:
$2
EOF
}
st() { k -n t patch landingzone "$1" --subresource=status --type merge -p "$2"; }
sp() { k -n t patch landingzone "$1" --type merge -p "$2"; }

mk lz
expect_ok "an empty landing zone is accepted and defaults apply" bash -c "[ \"\$(kubectl --context $CTX -n t get landingzone lz -o jsonpath='{.spec.deletionPolicy}/{.spec.parameters.workload}')\" = Orphan/Production ]"

# status write-once
expect_ok "subscription pinned" st lz '{"status":{"subscription":"lz","subscriptionUid":"u1","subscriptionId":"s1","providerConfigName":"lz"}}'
expect_ok "the same pin is re-applied" st lz '{"status":{"subscription":"lz","subscriptionUid":"u1","subscriptionId":"s1"}}'
expect_reject "status.subscription is write-once" "write-once" st lz '{"status":{"subscription":"other"}}'
expect_reject "status.subscription can't be removed" "write-once" st lz '{"status":{"subscription":null}}'
expect_reject "status.subscriptionUid is write-once" "write-once" st lz '{"status":{"subscriptionUid":"u2"}}'
expect_reject "status.subscriptionId is write-once" "write-once" st lz '{"status":{"subscriptionId":"s2"}}'
expect_reject "status.subscriptionId can't be removed" "write-once" st lz '{"status":{"subscriptionId":null}}'
expect_ok "environment pinned" st lz '{"status":{"environment":{"location":"westeurope","resourceGroupName":"rg-lz"}}}'
expect_ok "the same environment is re-applied" st lz '{"status":{"environment":{"location":"westeurope","resourceGroupName":"rg-lz"}}}'
expect_reject "the pinned location can't change" "write-once" st lz '{"status":{"environment":{"location":"northeurope"}}}'
expect_reject "the pinned resource group can't change" "write-once" st lz '{"status":{"environment":{"resourceGroupName":"rg-other"}}}'
expect_ok "network pinned once" st lz "{\"status\":{\"network\":{\"virtualNetwork\":\"lz\",\"subnetId\":\"$SUBNET\"}}}"
expect_ok "the same network is re-applied" st lz "{\"status\":{\"network\":{\"virtualNetwork\":\"lz\",\"subnetId\":\"$SUBNET\"}}}"
expect_reject "the pinned subnet can't change" "write-once" st lz "{\"status\":{\"network\":{\"subnetId\":\"${SUBNET}x\"}}}"
expect_reject "the pinned virtual network can't change" "write-once" st lz '{"status":{"network":{"virtualNetwork":"other"}}}'
expect_reject "the pinned network can't be removed" "write-once" st lz '{"status":{"network":null}}'
mk lz-nonet
expect_ok "environment pinned, no network yet" st lz-nonet '{"status":{"environment":{"location":"westeurope","resourceGroupName":"rg-lz-nonet"}}}'
expect_ok "network may be pinned later, once" st lz-nonet "{\"status\":{\"network\":{\"virtualNetwork\":\"v\",\"subnetId\":\"$SUBNET\"}}}"
expect_reject "and then it is fixed" "write-once" st lz-nonet "{\"status\":{\"network\":{\"subnetId\":\"${SUBNET}y\"}}}"
expect_ok "observed outputs can change" st lz '{"status":{"storageAccountName":"a","blobEndpoint":"https://a","keyVaultName":"b","keyVaultUri":"https://b"}}'
expect_ok "observed outputs can change again" st lz '{"status":{"storageAccountName":"c","keyVaultName":"d"}}'

# spec immutability
mk imm '  subscription: webshop-sub
  virtualNetwork: spoke
  parameters:
    workload: DevTest
    location: westeurope
    resourceGroupName: rg-imm'
expect_reject "spec.subscription can't change" "spec.subscription can't be changed" sp imm '{"spec":{"subscription":"other"}}'
expect_reject "spec.subscription can't be removed" "spec.subscription can't be changed" sp imm '{"spec":{"subscription":null}}'
expect_reject "spec.virtualNetwork can't change" "spec.virtualNetwork can't be changed" sp imm '{"spec":{"virtualNetwork":"other"}}'
expect_reject "spec.virtualNetwork can't be removed" "spec.virtualNetwork can't be changed" sp imm '{"spec":{"virtualNetwork":null}}'
expect_reject "spec.parameters.workload can't change" "workload can't be changed" sp imm '{"spec":{"parameters":{"workload":"Production"}}}'
expect_reject "spec.parameters.location can't change" "location can't be changed" sp imm '{"spec":{"parameters":{"location":"northeurope"}}}'
expect_reject "spec.parameters.resourceGroupName can't change" "resourceGroupName can't be changed" sp imm '{"spec":{"parameters":{"resourceGroupName":"rg-other"}}}'
expect_reject "spec.parameters.resourceGroupName can't be removed" "resourceGroupName can't be changed" sp imm '{"spec":{"parameters":{"resourceGroupName":null}}}'
mk late
expect_ok "spec.subscription can be set on a resource that had none" sp late '{"spec":{"subscription":"late-sub"}}'
expect_reject "and is then fixed" "spec.subscription can't be changed" sp late '{"spec":{"subscription":"later"}}'
expect_ok "tags and the deletion policy of a DevTest zone can change" sp imm '{"spec":{"deletionPolicy":"Delete","parameters":{"tags":{"owner":"x"}}}}'
expect_ok "and flip back" sp imm '{"spec":{"deletionPolicy":"Orphan"}}'

# Delete only with DevTest
expect_reject "deletionPolicy Delete on a Production zone" "Production landing zones are Orphan only" dry d1 '  deletionPolicy: Delete
  parameters:
    workload: Production'
expect_reject "deletionPolicy Delete with the default workload" "Production landing zones are Orphan only" dry d2 '  deletionPolicy: Delete'
expect_ok "deletionPolicy Delete on a DevTest zone" dry d3 '  deletionPolicy: Delete
  parameters:
    workload: DevTest'
expect_reject "a Production zone can't be switched to Delete" "Production landing zones are Orphan only" sp lz '{"spec":{"deletionPolicy":"Delete"}}'
expect_reject "deletionPolicy Retain" "Unsupported value" sp lz '{"spec":{"deletionPolicy":"Retain"}}'

# mutual exclusion and the need for a network
expect_reject "virtualNetwork together with parameters.network" "not both" dry m1 '  virtualNetwork: spoke
  parameters:
    network: {}'
expect_reject "storageAccount without a network" "need a virtual network" dry m2 '  parameters:
    storageAccount: {}'
expect_reject "keyVault without a network" "need a virtual network" dry m3 '  parameters:
    keyVault: {}'
expect_ok "storageAccount with parameters.network" dry m4 '  parameters:
    network: {}
    storageAccount: {}'
expect_ok "keyVault with an existing virtual network" dry m5 '  virtualNetwork: spoke
  parameters:
    keyVault: {}'

# names and tags
expect_reject "the reserved name default" "reserved" dry default '  {}'
expect_reject "the reserved platform- prefix" "reserved" dry platform-x '  {}'
expect_reject "a 31 character name" "at most 30" dry aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '  {}'
expect_reject "a tag key outside the allowlist" "Allowed tag keys" dry t1 '  parameters:
    tags:
      secret: x'
echo "all kind CEL tests passed"
