#!/usr/bin/env bash
# CEL tests for the KeyVault XRD that crossplane render can't run: status write-once
# (oldSelf rules) and spec immutability. The XRD schema is turned into a plain CRD (no
# Crossplane) and applied to a throwaway kind cluster that is deleted afterwards.
# Only the kind context is used. Needs kind, kubectl, ruby, Docker.
set -euo pipefail

cd "$(dirname "$0")/../.."
CLUSTER=${CLUSTER:-pr11-cel}
CTX=kind-$CLUSTER
WORK=tests/keyvault/.work-kind
mkdir -p "$WORK"
cleanup() { kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

kind create cluster --name "$CLUSTER" --wait 120s >/dev/null
k() { kubectl --context "$CTX" "$@"; }

ruby -ryaml -e '
  x = YAML.load_file("apis/keyvault/definition.yaml")
  v = x["spec"]["versions"][0]
  crd = { "apiVersion" => "apiextensions.k8s.io/v1", "kind" => "CustomResourceDefinition",
    "metadata" => { "name" => "keyvaults.platform.a5n.io" },
    "spec" => { "group" => "platform.a5n.io", "scope" => "Namespaced",
      "names" => { "kind" => "KeyVault", "plural" => "keyvaults" },
      "versions" => [{ "name" => "v1alpha1", "served" => true, "storage" => true,
        "subresources" => { "status" => {} }, "schema" => v["schema"] }] } }
  File.write(ARGV[0], crd.to_yaml)' "$WORK/crd.yaml"
k apply -f "$WORK/crd.yaml" >/dev/null
k wait --for=condition=Established crd/keyvaults.platform.a5n.io --timeout=60s >/dev/null
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
TENANT=11111111-2222-4333-8444-555555555555
mk() { # name [parameters-json]
  k -n t apply -f - >/dev/null <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: KeyVault
metadata:
  name: $1
spec:
  parameters: ${2:-{\}}
EOF
}
st() { k -n t patch keyvault "$1" --subresource=status --type merge -p "$2"; }
blk() { # [subnetId]
  local s=""
  [ -n "${1:-}" ] && s=",\"subnetId\":\"$1\""
  echo "{\"status\":{\"environment\":{\"location\":\"westeurope\",\"resourceGroupName\":\"rg\",\"tenantId\":\"$TENANT\"$s}}}"
}

mk with-subnet
mk no-subnet
expect_ok "environment pinned with a subnetId and tenantId" st with-subnet "$(blk $SUBNET)"
expect_ok "the unchanged block is re-applied" st with-subnet "$(blk $SUBNET)"
expect_reject "dropping the pinned subnetId is rejected" "write-once" st with-subnet '{"status":{"environment":{"subnetId":null}}}'
expect_reject "changing the pinned subnetId is rejected" "write-once" st with-subnet "$(blk ${SUBNET}x)"
expect_reject "changing the pinned tenantId is rejected" "write-once" st with-subnet '{"status":{"environment":{"tenantId":"22222222-2222-4333-8444-555555555555"}}}'
expect_ok "environment pinned without a subnetId" st no-subnet "$(blk)"
expect_reject "adding a subnetId to an existing pin is rejected" "write-once" st no-subnet "$(blk $SUBNET)"
expect_reject "the pinned location can't change" "write-once" st with-subnet '{"status":{"environment":{"location":"northeurope"}}}'

expect_ok "subscription pinned" st no-subnet '{"status":{"subscription":"sub-a","subscriptionUid":"u1","subscriptionId":"s1"}}'
expect_reject "status.subscription is write-once" "write-once" st no-subnet '{"status":{"subscription":"sub-b"}}'
expect_reject "status.subscriptionUid is write-once" "write-once" st no-subnet '{"status":{"subscriptionUid":"u2"}}'
expect_reject "status.subscriptionId is write-once" "write-once" st no-subnet '{"status":{"subscriptionId":"s2"}}'
expect_ok "vaultName pinned" st no-subnet '{"status":{"vaultName":"kvfixedname0000000000001"}}'
expect_ok "the same vaultName is re-applied" st no-subnet '{"status":{"vaultName":"kvfixedname0000000000001"}}'
expect_reject "status.vaultName is write-once" "write-once" st no-subnet '{"status":{"vaultName":"kvother"}}'
expect_reject "status.vaultName can't be removed" "write-once" st no-subnet '{"status":{"vaultName":null}}'
expect_ok "observed outputs can change" st no-subnet '{"status":{"resourceId":"b","privateEndpointId":"c","vaultUri":"https://x.vault.azure.net/"}}'

mk imm '{"name":"my-vault-01","location":"westeurope","resourceGroupName":"rg","softDeleteDays":30}'
imm() { k -n t patch keyvault imm --type merge -p "$1"; }
expect_reject "spec.parameters.name can't change" "can't be added, changed or removed" imm '{"spec":{"parameters":{"name":"other-vault"}}}'
expect_reject "spec.parameters.name can't be removed" "can't be added, changed or removed" imm '{"spec":{"parameters":{"name":null}}}'
mk noname
expect_reject "spec.parameters.name can't be added to an existing resource" "can't be added, changed or removed" k -n t patch keyvault noname --type merge -p '{"spec":{"parameters":{"name":"late-vault"}}}'
expect_reject "spec.parameters.location can't change" "can't be changed" imm '{"spec":{"parameters":{"location":"northeurope"}}}'
expect_reject "spec.parameters.resourceGroupName can't change" "can't be changed" imm '{"spec":{"parameters":{"resourceGroupName":"other"}}}'
expect_reject "spec.parameters.softDeleteDays can't change" "can't be changed" imm '{"spec":{"parameters":{"softDeleteDays":60}}}'
expect_ok "networking can change" imm '{"spec":{"parameters":{"networking":"public"}}}'

dry() { k -n t apply --dry-run=server -f - <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: KeyVault
metadata:
  name: dry
spec:
  parameters: $1
EOF
}
expect_reject "allowedIpRanges with private" "requires networking public" dry '{"networking":"private","allowedIpRanges":["203.0.113.0/24"]}'
expect_reject "a 25 character name" "" dry '{"name":"abcdefghijklmnopqrstuvwxy"}'
expect_reject "an uppercase name" "" dry '{"name":"MyVault"}'
expect_reject "two hyphens in a row" "" dry '{"name":"my--vault"}'
for n in 0 8 15; do
  expect_reject "allowedIpRanges prefix /$n" "/16 or narrower" dry "{\"networking\":\"public\",\"allowedIpRanges\":[\"203.0.113.0/$n\"]}"
done
expect_ok "allowedIpRanges prefix /16" dry '{"networking":"public","allowedIpRanges":["203.0.0.0/16"]}'
expect_reject "softDeleteDays 6" "" dry '{"softDeleteDays":6}'
expect_reject "softDeleteDays 91" "" dry '{"softDeleteDays":91}'
expect_ok "softDeleteDays 7" dry '{"softDeleteDays":7}'
expect_ok "deletionPolicy defaults to Orphan" bash -c "[ \"\$(kubectl --context $CTX -n t get keyvault with-subnet -o jsonpath='{.spec.deletionPolicy}')\" = Orphan ]"
expect_ok "networking defaults to private" bash -c "[ \"\$(kubectl --context $CTX -n t get keyvault with-subnet -o jsonpath='{.spec.parameters.networking}')\" = private ]"
expect_ok "softDeleteDays defaults to 90" bash -c "[ \"\$(kubectl --context $CTX -n t get keyvault with-subnet -o jsonpath='{.spec.parameters.softDeleteDays}')\" = 90 ]"
expect_reject "deletionPolicy Retain" "Unsupported value" k -n t patch keyvault imm --type merge -p '{"spec":{"deletionPolicy":"Retain"}}'
expect_ok "deletionPolicy Delete" k -n t patch keyvault imm --type merge -p '{"spec":{"deletionPolicy":"Delete"}}'
expect_ok "a 24 character name" dry '{"name":"abcdefghijklmnopqrstuvwx"}'
expect_ok "public with allowedIpRanges" dry '{"networking":"public","allowedIpRanges":["203.0.113.0/24"]}'
echo "all kind CEL tests passed"
