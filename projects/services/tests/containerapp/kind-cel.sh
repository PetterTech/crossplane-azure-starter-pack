#!/usr/bin/env bash
# CEL tests for the ContainerApp XRD that crossplane render can't run: status write-once
# (oldSelf rules) and spec immutability. The XRD schema is turned into a plain CRD (no
# Crossplane) and applied to a throwaway kind cluster that is deleted afterwards.
# Only the kind context is used. Needs kind, kubectl, ruby, Docker.
set -euo pipefail

cd "$(dirname "$0")/../.."
CLUSTER=${CLUSTER:-pr12-cel}
CTX=kind-$CLUSTER
WORK=tests/containerapp/.work-kind
mkdir -p "$WORK"
cleanup() { kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

kind create cluster --name "$CLUSTER" --wait 120s >/dev/null
k() { kubectl --context "$CTX" "$@"; }

ruby -ryaml -e '
  x = YAML.load_file("apis/containerapp/definition.yaml")
  v = x["spec"]["versions"][0]
  crd = { "apiVersion" => "apiextensions.k8s.io/v1", "kind" => "CustomResourceDefinition",
    "metadata" => { "name" => "containerapps.platform.a5n.io" },
    "spec" => { "group" => "platform.a5n.io", "scope" => "Namespaced",
      "names" => { "kind" => "ContainerApp", "plural" => "containerapps" },
      "versions" => [{ "name" => "v1alpha1", "served" => true, "storage" => true,
        "subresources" => { "status" => {} }, "schema" => v["schema"] }] } }
  File.write(ARGV[0], crd.to_yaml)' "$WORK/crd.yaml"
k apply -f "$WORK/crd.yaml" >/dev/null
k wait --for=condition=Established crd/containerapps.platform.a5n.io --timeout=60s >/dev/null
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
APPS=/subscriptions/cccccccc-1111-2222-3333-dddddddddddd/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/apps
IMG=ghcr.io/example/hello-api:1.0
mk() { # name [extra parameters, json object body without braces]
  k -n t apply -f - >/dev/null <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: ContainerApp
metadata:
  name: $1
spec:
  parameters: {"image":"$IMG"${2:+,$2}}
EOF
}
st() { k -n t patch containerapp "$1" --subresource=status --type merge -p "$2"; }
blk() { # [subnetId]
  local s=""
  [ -n "${1:-}" ] && s=",\"subnetId\":\"$1\""
  echo "{\"status\":{\"environment\":{\"location\":\"westeurope\",\"resourceGroupName\":\"rg\"$s}}}"
}

mk with-subnet
mk no-subnet
expect_ok "environment pinned with a subnetId" st with-subnet "$(blk $SUBNET)"
expect_ok "the unchanged block is re-applied" st with-subnet "$(blk $SUBNET)"
expect_reject "dropping the pinned subnetId is rejected" "write-once" st with-subnet '{"status":{"environment":{"subnetId":null}}}'
expect_reject "changing the pinned subnetId is rejected" "write-once" st with-subnet "$(blk ${SUBNET}x)"
expect_ok "environment pinned without a subnetId" st no-subnet "$(blk)"
expect_reject "adding a subnetId to an existing pin is rejected" "write-once" st no-subnet "$(blk $SUBNET)"
expect_reject "the pinned location can't change" "write-once" st with-subnet '{"status":{"environment":{"location":"northeurope"}}}'

expect_ok "subscription pinned" st no-subnet '{"status":{"subscription":"sub-a","subscriptionUid":"u1","subscriptionId":"s1"}}'
expect_reject "status.subscription is write-once" "write-once" st no-subnet '{"status":{"subscription":"sub-b"}}'
expect_reject "status.subscriptionUid is write-once" "write-once" st no-subnet '{"status":{"subscriptionUid":"u2"}}'
expect_reject "status.subscriptionId is write-once" "write-once" st no-subnet '{"status":{"subscriptionId":"s2"}}'
expect_ok "appName and environmentName pinned" st no-subnet '{"status":{"appName":"caapp0000000000000000001","environmentName":"caapp0000000000000000001-env"}}'
expect_ok "the same names are re-applied" st no-subnet '{"status":{"appName":"caapp0000000000000000001","environmentName":"caapp0000000000000000001-env"}}'
expect_reject "status.appName is write-once" "write-once" st no-subnet '{"status":{"appName":"other"}}'
expect_reject "status.appName can't be removed" "write-once" st no-subnet '{"status":{"appName":null}}'
expect_reject "status.environmentName is write-once" "write-once" st no-subnet '{"status":{"environmentName":"other-env"}}'
expect_reject "status.environmentName can't be removed" "write-once" st no-subnet '{"status":{"environmentName":null}}'
expect_ok "observed outputs can change" st no-subnet '{"status":{"resourceId":"b","environmentId":"c","defaultDomain":"d","fqdn":"e","url":"https://e","principalId":"p","privateEndpointId":"f"}}'

mk imm "\"name\":\"my-app-01\",\"location\":\"westeurope\",\"resourceGroupName\":\"rg\",\"infrastructureSubnetId\":\"$APPS\",\"zoneRedundant\":true"
imm() { k -n t patch containerapp imm --type merge -p "$1"; }
expect_reject "spec.parameters.name can't change" "can't be added, changed or removed" imm '{"spec":{"parameters":{"name":"other-app"}}}'
expect_reject "spec.parameters.name can't be removed" "can't be added, changed or removed" imm '{"spec":{"parameters":{"name":null}}}'
mk noname
expect_reject "spec.parameters.name can't be added to an existing resource" "can't be added, changed or removed" k -n t patch containerapp noname --type merge -p '{"spec":{"parameters":{"name":"late-app"}}}'
expect_reject "spec.parameters.infrastructureSubnetId can't be added to an existing resource" "infrastructureSubnetId can't be added, changed or removed" k -n t patch containerapp noname --type merge -p "{\"spec\":{\"parameters\":{\"infrastructureSubnetId\":\"$APPS\"}}}"
expect_reject "spec.parameters.infrastructureSubnetId can't change" "infrastructureSubnetId can't be added, changed or removed" imm "{\"spec\":{\"parameters\":{\"infrastructureSubnetId\":\"${APPS}2\"}}}"
expect_reject "spec.parameters.infrastructureSubnetId can't be removed" "infrastructureSubnetId can't be added, changed or removed" imm '{"spec":{"parameters":{"infrastructureSubnetId":null}}}'
expect_reject "spec.parameters.location can't change" "can't be changed" imm '{"spec":{"parameters":{"location":"northeurope"}}}'
expect_reject "spec.parameters.resourceGroupName can't change" "can't be changed" imm '{"spec":{"parameters":{"resourceGroupName":"other"}}}'
expect_reject "spec.parameters.networking can't change" "can't be changed" imm '{"spec":{"parameters":{"networking":"public"}}}'
expect_reject "spec.parameters.zoneRedundant can't change" "can't be changed" imm '{"spec":{"parameters":{"zoneRedundant":false}}}'
expect_ok "size, replicas and the image can change" imm '{"spec":{"parameters":{"size":"large","minReplicas":2,"maxReplicas":4,"image":"ghcr.io/example/hello-api:1.1"}}}'
expect_reject "the image can't change to :latest" "must not use the :latest tag" imm '{"spec":{"parameters":{"image":"ghcr.io/example/hello-api:latest"}}}'

dry() { k -n t apply --dry-run=server -f - <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: ContainerApp
metadata:
  name: dry
spec:
  parameters: $1
EOF
}
expect_reject "external ingress with private networking" "ingress external requires networking public" dry "{\"image\":\"$IMG\",\"ingress\":\"external\"}"
expect_reject "zoneRedundant without infrastructureSubnetId" "zoneRedundant requires infrastructureSubnetId" dry "{\"image\":\"$IMG\",\"zoneRedundant\":true}"
expect_reject "minReplicas greater than maxReplicas" "can't be greater than maxReplicas" dry "{\"image\":\"$IMG\",\"minReplicas\":4,\"maxReplicas\":2}"
expect_reject "image :latest" "must not use the :latest tag" dry '{"image":"ghcr.io/example/hello-api:latest"}'
expect_reject "image without a tag" "must have a tag or a digest" dry '{"image":"ghcr.io/example/hello-api"}'
expect_reject "a 33 character name" "" dry "{\"image\":\"$IMG\",\"name\":\"abcdefghijklmnopqrstuvwxyzabcdefg\"}"
expect_reject "an uppercase name" "" dry "{\"image\":\"$IMG\",\"name\":\"MyApp\"}"
expect_reject "two hyphens in a row" "" dry "{\"image\":\"$IMG\",\"name\":\"my--app\"}"
expect_ok "public with external ingress" dry "{\"image\":\"$IMG\",\"networking\":\"public\",\"ingress\":\"external\"}"
expect_ok "zoneRedundant with infrastructureSubnetId" dry "{\"image\":\"$IMG\",\"zoneRedundant\":true,\"infrastructureSubnetId\":\"$APPS\"}"
expect_ok "a digest-pinned image" dry '{"image":"ghcr.io/example/hello-api@sha256:3f1c9a7e5b2d48c6a0e9d1f47b8c2a6e5d0f9b3c71a4e8d2c6b0f5a9e3d71c48"}'
expect_ok "deletionPolicy defaults to Orphan" bash -c "[ \"\$(kubectl --context $CTX -n t get containerapp with-subnet -o jsonpath='{.spec.deletionPolicy}')\" = Orphan ]"
expect_ok "networking defaults to private" bash -c "[ \"\$(kubectl --context $CTX -n t get containerapp with-subnet -o jsonpath='{.spec.parameters.networking}')\" = private ]"
expect_ok "ingress defaults to internal" bash -c "[ \"\$(kubectl --context $CTX -n t get containerapp with-subnet -o jsonpath='{.spec.parameters.ingress}')\" = internal ]"
expect_ok "identity defaults to none" bash -c "[ \"\$(kubectl --context $CTX -n t get containerapp with-subnet -o jsonpath='{.spec.parameters.identity}')\" = none ]"
expect_reject "deletionPolicy Retain" "Unsupported value" k -n t patch containerapp imm --type merge -p '{"spec":{"deletionPolicy":"Retain"}}'
expect_ok "deletionPolicy Delete" k -n t patch containerapp imm --type merge -p '{"spec":{"deletionPolicy":"Delete"}}'
echo "all kind CEL tests passed"
