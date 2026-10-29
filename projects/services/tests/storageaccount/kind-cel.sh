#!/usr/bin/env bash
# CEL tests for the StorageAccount XRD that crossplane render can't run: status write-once
# (oldSelf rules) and spec immutability. The XRD schema is turned into a plain CRD (no
# Crossplane) and applied to a throwaway kind cluster that is deleted afterwards.
# Only the kind context is used. Needs kind, kubectl, ruby, Docker.
set -euo pipefail

cd "$(dirname "$0")/../.."
CLUSTER=pr10-cel
CTX=kind-$CLUSTER
WORK=tests/storageaccount/.work-kind
mkdir -p "$WORK"
cleanup() { kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

kind create cluster --name "$CLUSTER" --wait 120s >/dev/null
k() { kubectl --context "$CTX" "$@"; }

ruby -ryaml -e '
  x = YAML.load_file("apis/storageaccount/definition.yaml")
  v = x["spec"]["versions"][0]
  crd = { "apiVersion" => "apiextensions.k8s.io/v1", "kind" => "CustomResourceDefinition",
    "metadata" => { "name" => "storageaccounts.platform.a5n.io" },
    "spec" => { "group" => "platform.a5n.io", "scope" => "Namespaced",
      "names" => { "kind" => "StorageAccount", "plural" => "storageaccounts" },
      "versions" => [{ "name" => "v1alpha1", "served" => true, "storage" => true,
        "subresources" => { "status" => {} }, "schema" => v["schema"] }] } }
  File.write(ARGV[0], crd.to_yaml)' "$WORK/crd.yaml"
k apply -f "$WORK/crd.yaml" >/dev/null
k wait --for=condition=Established crd/storageaccounts.platform.a5n.io --timeout=60s >/dev/null
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
mk() { # name [parameters-json]
  k -n t apply -f - >/dev/null <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: StorageAccount
metadata:
  name: $1
spec:
  parameters: ${2:-{\}}
EOF
}
st() { k -n t patch storageaccount "$1" --subresource=status --type merge -p "$2"; }
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
expect_ok "observed outputs can change" st no-subnet '{"status":{"accountName":"a","resourceId":"b","privateEndpointId":"c"}}'

mk imm '{"name":"stfixedname01","location":"westeurope","resourceGroupName":"rg"}'
imm() { k -n t patch storageaccount imm --type merge -p "$1"; }
expect_reject "spec.parameters.name can't change" "can't be changed" imm '{"spec":{"parameters":{"name":"stother"}}}'
expect_reject "spec.parameters.location can't change" "can't be changed" imm '{"spec":{"parameters":{"location":"northeurope"}}}'
expect_reject "spec.parameters.resourceGroupName can't change" "can't be changed" imm '{"spec":{"parameters":{"resourceGroupName":"other"}}}'
expect_ok "networking can change" imm '{"spec":{"parameters":{"networking":"public"}}}'

dry() { k -n t apply --dry-run=server -f - <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: StorageAccount
metadata:
  name: dry
spec:
  parameters: $1
EOF
}
expect_reject "Premium with StorageV2" "Premium" dry '{"accountTier":"Premium"}'
expect_reject "BlockBlobStorage with Standard" "" dry '{"accountKind":"BlockBlobStorage"}'
expect_reject "containers on FileStorage" "FileStorage" dry '{"accountKind":"FileStorage","accountTier":"Premium","containers":[{"name":"a"}]}'
expect_reject "allowedIpRanges with private" "" dry '{"networking":"private","allowedIpRanges":["203.0.113.0/24"]}'
expect_reject "a 25 character name" "" dry '{"name":"abcdefghijklmnopqrstuvwxy"}'
expect_ok "a 24 character name" dry '{"name":"abcdefghijklmnopqrstuvwx"}'
expect_ok "public with allowedIpRanges" dry '{"networking":"public","allowedIpRanges":["203.0.113.0/24"]}'
echo "all kind CEL tests passed"
