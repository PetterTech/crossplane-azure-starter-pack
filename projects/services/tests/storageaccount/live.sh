#!/usr/bin/env bash
# Live check of the StorageAccount composition on a throwaway kind cluster with a real Crossplane
# and the pinned functions. No provider runs: only the provider CRDs are installed (the API server
# validates the composed managed resources against them) and the managed resources' status is
# patched by hand. Only the kind context is used and the cluster is deleted afterwards.
# Needs kind, kubectl, helm, ruby, Docker and network access. Takes several minutes.
set -euo pipefail

cd "$(dirname "$0")/../.."
T=tests/storageaccount
CLUSTER=pr10-live
CTX=kind-$CLUSTER
trap 'kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true' EXIT
k() { kubectl --context "$CTX" "$@"; }
ok() { echo "PASS $1"; }
die() { echo "FAIL $1"; k -n team-a get storageaccount,accounts.storage.azure.m.upbound.io,containers.storage.azure.m.upbound.io,privateendpoints.network.azure.m.upbound.io 2>&1 | head -20; exit 1; }
wait_for() { # description timeout command...
  local d=$1 t=$2; shift 2
  for _ in $(seq "$t"); do if "$@" >/dev/null 2>&1; then ok "$d"; return; fi; sleep 2; done
  die "$d"
}

kind create cluster --name "$CLUSTER" --wait 120s >/dev/null
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm --kube-context "$CTX" install crossplane crossplane-stable/crossplane --version 2.4.3 -n crossplane-system --create-namespace --wait >/dev/null
ok "Crossplane installed"

k apply -f ../../setup/functions.yaml >/dev/null
wait_for "functions healthy" 90 bash -c "[ \$(kubectl --context $CTX get functions -o jsonpath='{range .items[*]}{.status.conditions[?(@.type==\"Healthy\")].status}{\"\\n\"}{end}' | grep -c True) -eq 5 ]"

# provider CRDs without the conversion webhook
for f in account container privateendpoint; do
  ruby -ryaml -e 'c = YAML.load_file(ARGV[0]); c["spec"]["conversion"] = { "strategy" => "None" }; puts c.to_yaml' "$T/crds/$f.yaml" | k apply -f - >/dev/null
done
k apply -f - >/dev/null <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: subscriptions.platform.a5n.io}
spec:
  group: platform.a5n.io
  scope: Namespaced
  names: {kind: Subscription, plural: subscriptions}
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources: {status: {}}
      schema: {openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: live-test-crossplane
  labels: {rbac.crossplane.io/aggregate-to-crossplane: "true"}
rules:
  - apiGroups: [platform.a5n.io]
    resources: [subscriptions]
    verbs: [get, list, watch]
  - apiGroups: [storage.azure.m.upbound.io, network.azure.m.upbound.io]
    resources: ["*"]
    verbs: ["*"]
EOF
k apply -f "$T/env.yaml" >/dev/null
k apply -f apis/storageaccount/definition.yaml >/dev/null
k apply -f apis/storageaccount/composition.yaml >/dev/null
wait_for "XRD established" 60 k wait --for=condition=Established xrd/storageaccounts.platform.a5n.io --timeout=1s
k create namespace team-a >/dev/null

k -n team-a apply -f - >/dev/null <<'EOF'
apiVersion: platform.a5n.io/v1alpha1
kind: Subscription
metadata: {name: sub-a}
spec: {}
EOF
k -n team-a patch subscription sub-a --subresource=status --type merge -p '{"status":{"subscriptionId":"eeeeeeee-1111-2222-3333-ffffffffffff","conditions":[{"type":"Ready","status":"True","reason":"Available","lastTransitionTime":"2024-01-01T00:00:00Z"}]}}' >/dev/null

k -n team-a apply -f - >/dev/null <<'EOF'
apiVersion: platform.a5n.io/v1alpha1
kind: StorageAccount
metadata: {name: data}
spec:
  parameters:
    containers: [{name: raw}, {name: curated}]
    tags: {costCenter: "0000"}
EOF

sa() { k -n team-a get storageaccount data -o jsonpath="$1"; }
wait_for "resolver pinned subscription and environment" 90 bash -c "[ \"\$(kubectl --context $CTX -n team-a get storageaccount data -o jsonpath='{.status.environment.subnetId}')\" != '' ]"
wait_for "account composed and accepted by the provider CRD (retention policies are objects)" 90 bash -c "kubectl --context $CTX -n team-a get accounts.storage.azure.m.upbound.io -o name | grep -q ."

ACC=$(k -n team-a get accounts.storage.azure.m.upbound.io -o jsonpath='{.items[0].metadata.name}')
NAME=$(k -n team-a get accounts.storage.azure.m.upbound.io "$ACC" -o jsonpath='{.metadata.annotations.crossplane\.io/external-name}')
[[ $NAME =~ ^st[a-z0-9]{22}$ ]] && ok "derived name $NAME is 24 lowercase alphanumeric characters" || die "derived name $NAME"
[ "$(k -n team-a get accounts.storage.azure.m.upbound.io "$ACC" -o jsonpath='{.spec.forProvider.blobProperties.deleteRetentionPolicy.days}')" = 7 ] && ok "deleteRetentionPolicy.days is 7 as an object" || die "retention"
[ "$(k -n team-a get accounts.storage.azure.m.upbound.io "$ACC" -o jsonpath='{.spec.managementPolicies}')" = '["Create","Observe","Update","LateInitialize"]' ] && ok "Orphan: no Delete in managementPolicies" || die "managementPolicies"
wait_for "status.accountName pinned to the derived name" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get storageaccount data -o jsonpath='{.status.accountName}')\" = $NAME ]"
[ "$(k -n team-a get accounts.storage.azure.m.upbound.io "$ACC" -o jsonpath='{.spec.providerConfigRef.name}')" = sub-a ] && ok "ProviderConfig is the Subscription name" || die "providerConfigRef"
out=$(k -n team-a patch storageaccount data --subresource=status --type merge -p '{"status":{"accountName":"stother"}}' 2>&1 || true)
if grep -q write-once <<<"$out"; then ok "status.accountName is write-once on a live Crossplane XRD"; else echo "$out"; die "accountName write-once"; fi

# the account becomes ready: containers and the endpoint follow
ID=/subscriptions/eeeeeeee-1111-2222-3333-ffffffffffff/resourceGroups/rg-test-default/providers/Microsoft.Storage/storageAccounts/$NAME
k -n team-a patch accounts.storage.azure.m.upbound.io "$ACC" --subresource=status --type merge -p "{\"status\":{\"atProvider\":{\"id\":\"$ID\",\"primaryBlobEndpoint\":\"https://$NAME.blob.core.windows.net/\",\"primaryFileEndpoint\":\"https://$NAME.file.core.windows.net/\"},\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"reason\":\"Available\",\"lastTransitionTime\":\"2024-01-01T00:00:00Z\"}]}}" >/dev/null
wait_for "two containers and one private endpoint composed" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get containers.storage.azure.m.upbound.io -o name | wc -l) -eq 2 ] && [ \$(kubectl --context $CTX -n team-a get privateendpoints.network.azure.m.upbound.io -o name | wc -l) -eq 1 ]"
[ "$(k -n team-a get privateendpoints.network.azure.m.upbound.io -o jsonpath='{.items[0].spec.forProvider.privateServiceConnection.subresourceNames[0]}')" = blob ] && ok "endpoint targets blob" || die "subresource"
[ "$(sa '{.status.conditions[?(@.type=="Ready")].status}')" != True ] && ok "XR not Ready while the children are not" || die "ready too early"

# a second reconcile with the pin in place must not recompose the account name
wait_for "status.resourceId projected" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get storageaccount data -o jsonpath='{.status.resourceId}')\" = $ID ]"
[ "$(k -n team-a get accounts.storage.azure.m.upbound.io -o jsonpath='{.items[0].metadata.annotations.crossplane\.io/external-name}')" = "$NAME" ] && ok "account name stable across reconciles" || die "name changed"

# deletionPolicy Delete flips the managementPolicies
k -n team-a patch storageaccount data --type merge -p '{"spec":{"deletionPolicy":"Delete"}}' >/dev/null
wait_for "deletionPolicy Delete gives managementPolicies *" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get accounts.storage.azure.m.upbound.io -o jsonpath='{.items[0].spec.managementPolicies}')\" = '[\"*\"]' ]"

# private without a platform subnet: Fatal, nothing created, not Ready
k apply -f - >/dev/null <<'EOF'
apiVersion: apiextensions.crossplane.io/v1beta1
kind: EnvironmentConfig
metadata: {name: platform-environment}
data:
  location: westeurope
  resourceGroupName: rg-test-default
EOF
k -n team-a apply -f - >/dev/null <<'EOF'
apiVersion: platform.a5n.io/v1alpha1
kind: StorageAccount
metadata: {name: nosubnet}
spec: {}
EOF
wait_for "private without subnetId: Synced=False SubnetNotConfigured" 60 bash -c "kubectl --context $CTX -n team-a get storageaccount nosubnet -o jsonpath='{.status.conditions[?(@.type==\"Synced\")].message}' | grep -q SubnetNotConfigured"
[ -z "$(k -n team-a get storageaccount nosubnet -o jsonpath='{.status.environment}')" ] && [ "$(k -n team-a get storageaccount nosubnet -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != True ] && ok "nothing pinned, not Ready" || die "nosubnet state"
[ "$(k -n team-a get accounts.storage.azure.m.upbound.io -o name | wc -l)" -eq 1 ] && ok "no second account created" || die "unexpected account"
echo "all live checks passed"
