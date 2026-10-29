#!/usr/bin/env bash
# Transition-rule tests for the Subscription XRD (workload immutability, status write-once).
# `crossplane resource validate` can't evaluate oldSelf rules, so the XRD schema is turned into a
# plain CRD (no Crossplane) and applied to a throwaway kind cluster that is deleted afterwards.
# Only the kind context is used. Needs kind, kubectl, ruby, Docker.
set -euo pipefail

cd "$(dirname "$0")/../.."
CLUSTER=pr08-cel
CTX=kind-$CLUSTER
WORK=tests/subscription/.work-kind
mkdir -p "$WORK"
cleanup() { kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

kind create cluster --name "$CLUSTER" --wait 120s >/dev/null
k() { kubectl --context "$CTX" "$@"; }

ruby -ryaml -e '
  x = YAML.load_file("apis/subscription/definition.yaml")
  v = x["spec"]["versions"][0]
  crd = { "apiVersion" => "apiextensions.k8s.io/v1", "kind" => "CustomResourceDefinition",
    "metadata" => { "name" => "subscriptions.platform.a5n.io" },
    "spec" => { "group" => "platform.a5n.io", "scope" => "Namespaced",
      "names" => { "kind" => "Subscription", "plural" => "subscriptions" },
      "versions" => [{ "name" => "v1alpha1", "served" => true, "storage" => true,
        "subresources" => { "status" => {} }, "schema" => v["schema"] }] } }
  File.write(ARGV[0], crd.to_yaml)' "$WORK/crd.yaml"
k apply -f "$WORK/crd.yaml" >/dev/null
k wait --for=condition=Established crd/subscriptions.platform.a5n.io --timeout=60s >/dev/null
k create namespace t >/dev/null

expect_ok() { # name command...
  local n=$1; shift
  if out=$("$@" 2>&1); then echo "PASS $n"; else echo "FAIL $n: $out"; exit 1; fi
}
expect_reject() { # name pattern command...
  local n=$1 pat=$2; shift 2
  if out=$("$@" 2>&1); then echo "FAIL $n: accepted"; exit 1; fi
  if grep -q "$pat" <<<"$out"; then echo "PASS $n"; else echo "FAIL $n: $out"; exit 1; fi
}

k -n t apply -f - >/dev/null <<'EOF'
apiVersion: platform.a5n.io/v1alpha1
kind: Subscription
metadata:
  name: sub-a
spec:
  workload: DevTest
EOF

expect_reject "workload can't be changed" "can't be changed once set" \
  k -n t patch subscription sub-a --type merge -p '{"spec":{"workload":"Production"}}'
expect_reject "workload can't be removed" "can't be changed once set" \
  k -n t patch subscription sub-a --type json -p '[{"op":"remove","path":"/spec/workload"}]'

SID=eeeeeeee-1111-2222-3333-ffffffffffff
st() { k -n t patch subscription sub-a --subresource=status --type merge -p "$1"; }
expect_ok "status.subscriptionId can be set once" st "{\"status\":{\"subscriptionId\":\"$SID\"}}"
expect_ok "status.subscriptionId can be re-written with the same value" st "{\"status\":{\"subscriptionId\":\"$SID\"}}"
expect_reject "status.subscriptionId can't change" "write-once" st '{"status":{"subscriptionId":"dddddddd-1111-2222-3333-ffffffffffff"}}'
expect_reject "status.subscriptionId can't be removed" "write-once" st '{"status":{"subscriptionId":null}}'

expect_ok "status.providerConfigName can be set once" st '{"status":{"providerConfigName":"sub-a"}}'
expect_reject "status.providerConfigName can't change" "write-once" st '{"status":{"providerConfigName":"other"}}'
expect_ok "status.identity can be set once" st '{"status":{"identity":{"clientId":"c1"}}}'
expect_reject "status.identity can't change" "write-once" st '{"status":{"identity":{"clientId":"c2"}}}'
expect_ok "status.environment can be set once" st '{"status":{"environment":{"location":"westeurope"}}}'
expect_reject "status.environment can't change" "write-once" st '{"status":{"environment":{"location":"northeurope"}}}'
expect_ok "status.subscriptionUid can be set once" st '{"status":{"subscriptionUid":"u1"}}'
expect_reject "status.subscriptionUid can't change" "write-once" st '{"status":{"subscriptionUid":"u2"}}'
echo "all kind CEL transition tests passed"
