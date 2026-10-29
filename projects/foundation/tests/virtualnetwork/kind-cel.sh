#!/usr/bin/env bash
# CEL tests for the VirtualNetwork XRD that crossplane render can't run: status write-once
# (oldSelf rules) and the allowInbound source rule. The XRD schema is turned into a plain CRD
# (no Crossplane) and applied to a throwaway kind cluster that is deleted afterwards.
# Only the kind context is used. Needs kind, kubectl, ruby, Docker.
set -euo pipefail

cd "$(dirname "$0")/../.."
CLUSTER=pr09-cel
CTX=kind-$CLUSTER
WORK=tests/virtualnetwork/.work-kind
mkdir -p "$WORK"
cleanup() { kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

kind create cluster --name "$CLUSTER" --wait 120s >/dev/null
k() { kubectl --context "$CTX" "$@"; }

ruby -ryaml -e '
  x = YAML.load_file("apis/virtualnetwork/definition.yaml")
  v = x["spec"]["versions"][0]
  crd = { "apiVersion" => "apiextensions.k8s.io/v1", "kind" => "CustomResourceDefinition",
    "metadata" => { "name" => "virtualnetworks.platform.a5n.io" },
    "spec" => { "group" => "platform.a5n.io", "scope" => "Namespaced",
      "names" => { "kind" => "VirtualNetwork", "plural" => "virtualnetworks" },
      "versions" => [{ "name" => "v1alpha1", "served" => true, "storage" => true,
        "subresources" => { "status" => {} }, "schema" => v["schema"] }] } }
  File.write(ARGV[0], crd.to_yaml)' "$WORK/crd.yaml"
k apply -f "$WORK/crd.yaml" >/dev/null
k wait --for=condition=Established crd/virtualnetworks.platform.a5n.io --timeout=60s >/dev/null
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

IPAM=/subscriptions/cccccccc-1111-2222-3333-dddddddddddd/resourceGroups/rg/providers/Microsoft.Network/networkManagers/nm/ipamPools/p
HUB=/subscriptions/cccccccc-1111-2222-3333-dddddddddddd/resourceGroups/rg/providers/Microsoft.Network/virtualHubs/h
mk() {
  k -n t apply -f - >/dev/null <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: VirtualNetwork
metadata:
  name: $1
spec: {}
EOF
}
st() { k -n t patch virtualnetwork "$1" --subresource=status --type merge -p "$2"; }
blk() { # ipam [hub]
  local h=""
  [ -n "${2:-}" ] && h=",\"hubVirtualHubId\":\"$2\""
  echo "{\"status\":{\"environment\":{\"location\":\"westeurope\",\"resourceGroupName\":\"rg\",\"ipamPoolId\":\"$1\"$h}}}"
}

# The resolver pins the whole block once and re-emits it unchanged (run.sh: hub added/removed later).
mk no-hub
mk with-hub
expect_ok "environment pinned without a hub" st no-hub "$(blk $IPAM)"
expect_ok "hub added to the environment later: the unchanged block is re-applied" st no-hub "$(blk $IPAM)"
expect_reject "writing a live hub into an existing pin is rejected" "write-once" st no-hub "$(blk $IPAM $HUB)"
expect_ok "environment pinned with a hub" st with-hub "$(blk $IPAM $HUB)"
expect_ok "hub removed from the environment later: the unchanged block is re-applied" st with-hub "$(blk $IPAM $HUB)"
expect_reject "dropping the pinned hub is rejected" "write-once" st with-hub '{"status":{"environment":{"hubVirtualHubId":null}}}'
expect_reject "the pinned ipamPoolId can't change" "write-once" st with-hub "$(blk ${IPAM}x $HUB)"

src() { # prefix [port]
  k -n t apply --dry-run=server -f - <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: VirtualNetwork
metadata:
  name: src-test
spec:
  parameters:
    networkSecurityGroup:
      allowInbound:
        - name: r
          port: ${2:-443}
          sourceAddressPrefix: "$1"
EOF
}
for p in VirtualNetwork 10.1.0.0/16 172.16.0.0/12 192.168.1.0/24; do expect_ok "source $p is accepted" src "$p"; done
for p in 0.0.0.0/0 0.0.0.0/1 128.0.0.0/1 1.0.0.0/8 999.999.999.999/8 10.256.0.0/16 172.32.0.0/16 Internet '*'; do
  expect_reject "source $p is rejected" "RFC 1918" src "$p"
done
expect_reject "a public source on port 22 is rejected" "RFC 1918" src 8.8.8.8/32 22
expect_reject "a public source on port 3389 is rejected" "RFC 1918" src 0.0.0.0/0 3389
echo "all kind CEL tests passed"
