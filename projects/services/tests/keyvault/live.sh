#!/usr/bin/env bash
# Live check of the KeyVault composition on a throwaway kind cluster with a real Crossplane
# and the pinned functions. No provider runs: only the provider CRDs are installed (the API server
# validates the composed managed resources against them) and the managed resources' status is
# patched by hand. Only the kind context is used and the cluster is deleted afterwards.
# Needs kind, kubectl, helm, ruby, Docker and network access. Takes several minutes.
set -euo pipefail

cd "$(dirname "$0")/../.."
T=tests/keyvault
CLUSTER=${CLUSTER:-pr11-live}
CTX=kind-$CLUSTER
trap 'kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true' EXIT
k() { kubectl --context "$CTX" "$@"; }
ok() { echo "PASS $1"; }
die() { echo "FAIL $1"; k -n team-a get keyvault,vaults.keyvault.azure.m.upbound.io,privateendpoints.network.azure.m.upbound.io 2>&1 | head -20; exit 1; }
wait_for() { # description timeout command...
  local d=$1 t=$2; shift 2
  for _ in $(seq "$t"); do if "$@" >/dev/null 2>&1; then ok "$d"; return; fi; sleep 2; done
  die "$d"
}
VAULTS=vaults.keyvault.azure.m.upbound.io
PES=privateendpoints.network.azure.m.upbound.io
kv() { k -n team-a get keyvault secrets -o jsonpath="$1"; }
vault() { k -n team-a get $VAULTS -o jsonpath="{.items[0]$1}"; }

kind create cluster --name "$CLUSTER" --wait 120s >/dev/null
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm --kube-context "$CTX" install crossplane crossplane-stable/crossplane --version 2.4.3 -n crossplane-system --create-namespace --wait >/dev/null
ok "Crossplane installed"

k apply -f ../../setup/functions.yaml >/dev/null
wait_for "functions healthy" 90 bash -c "[ \$(kubectl --context $CTX get functions -o jsonpath='{range .items[*]}{.status.conditions[?(@.type==\"Healthy\")].status}{\"\\n\"}{end}' | grep -c True) -eq 5 ]"

# provider CRDs without the conversion webhook
for f in vault privateendpoint; do
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
  - apiGroups: [keyvault.azure.m.upbound.io, network.azure.m.upbound.io]
    resources: ["*"]
    verbs: ["*"]
EOF
k apply -f "$T/env.yaml" >/dev/null
k apply -f apis/keyvault/definition.yaml >/dev/null
k apply -f apis/keyvault/composition.yaml >/dev/null
wait_for "XRD established" 60 k wait --for=condition=Established xrd/keyvaults.platform.a5n.io --timeout=1s
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
kind: KeyVault
metadata: {name: secrets}
spec:
  parameters:
    tags: {costCenter: "0000"}
EOF

wait_for "resolver pinned subscription, tenant and subnet" 90 bash -c "[ \"\$(kubectl --context $CTX -n team-a get keyvault secrets -o jsonpath='{.status.environment.subnetId}')\" != '' ] && [ \"\$(kubectl --context $CTX -n team-a get keyvault secrets -o jsonpath='{.status.environment.tenantId}')\" = 11111111-2222-4333-8444-555555555555 ]"
wait_for "vault composed and accepted by the provider CRD (networkAcls is an object)" 90 bash -c "kubectl --context $CTX -n team-a get $VAULTS -o name | grep -q ."

VLT=$(vault '.metadata.name')
NAME=$(vault '.metadata.annotations.crossplane\.io/external-name')
[[ $NAME =~ ^kv[a-z0-9]{22}$ ]] && ok "derived name $NAME is 24 lowercase characters starting with a letter" || die "derived name $NAME"
[ "$(vault '.spec.forProvider.networkAcls.defaultAction')" = Deny ] && [ "$(vault '.spec.forProvider.publicNetworkAccessEnabled')" = false ] && [ "$(vault '.spec.forProvider.rbacAuthorizationEnabled')" = true ] && [ "$(vault '.spec.forProvider.purgeProtectionEnabled')" = true ] && ok "private, RBAC, purge protection, firewall Deny" || die "hardening"
[ "$(vault '.spec.forProvider.tenantId')" = 11111111-2222-4333-8444-555555555555 ] && ok "tenantId comes from the pinned environment" || die "tenantId"
[ "$(vault '.spec.managementPolicies')" = '["Create","Observe","Update","LateInitialize"]' ] && ok "Orphan: no Delete in managementPolicies" || die "managementPolicies"
wait_for "status.vaultName pinned to the derived name" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get keyvault secrets -o jsonpath='{.status.vaultName}')\" = $NAME ]"
[ "$(vault '.spec.providerConfigRef.name')" = sub-a ] && ok "ProviderConfig is the Subscription name" || die "providerConfigRef"
out=$(k -n team-a patch keyvault secrets --subresource=status --type merge -p '{"status":{"vaultName":"kvother"}}' 2>&1 || true)
if grep -q write-once <<<"$out"; then ok "status.vaultName is write-once on a live Crossplane XRD"; else echo "$out"; die "vaultName write-once"; fi

# adding a name to an existing vault is rejected (it would swap the external name)
out=$(k -n team-a patch keyvault secrets --type merge -p '{"spec":{"parameters":{"name":"late-name"}}}' 2>&1 || true)
if grep -q "can't be added, changed or removed" <<<"$out"; then ok "adding spec.parameters.name to an existing vault is rejected"; else echo "$out"; die "name add"; fi

# the vault becomes ready: the private endpoint follows
ID=/subscriptions/eeeeeeee-1111-2222-3333-ffffffffffff/resourceGroups/rg-test-default/providers/Microsoft.KeyVault/vaults/$NAME
k -n team-a patch $VAULTS "$VLT" --subresource=status --type merge -p "{\"status\":{\"atProvider\":{\"id\":\"$ID\",\"vaultUri\":\"https://$NAME.vault.azure.net/\"},\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"reason\":\"Available\",\"lastTransitionTime\":\"2024-01-01T00:00:00Z\"}]}}" >/dev/null
wait_for "one private endpoint composed" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get $PES -o name | wc -l) -eq 1 ]"
[ "$(k -n team-a get $PES -o jsonpath='{.items[0].spec.forProvider.privateServiceConnection.subresourceNames[0]}')" = vault ] && ok "endpoint targets the vault group" || die "subresource"
[ "$(kv '{.status.conditions[?(@.type=="Ready")].status}')" != True ] && ok "XR not Ready while the endpoint is not" || die "ready too early"
wait_for "status.resourceId and vaultUri projected" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get keyvault secrets -o jsonpath='{.status.resourceId}')\" = $ID ] && [ \"\$(kubectl --context $CTX -n team-a get keyvault secrets -o jsonpath='{.status.vaultUri}')\" = https://$NAME.vault.azure.net/ ]"

# function-kro restart: the name, the pin and the composed resources are unchanged
k -n crossplane-system delete pod -l pkg.crossplane.io/function=function-kro >/dev/null
sleep 5
wait_for "function-kro healthy again" 90 bash -c "kubectl --context $CTX get function function-kro -o jsonpath='{.status.conditions[?(@.type==\"Healthy\")].status}' | grep -q True && kubectl --context $CTX -n crossplane-system get pod -l pkg.crossplane.io/function=function-kro -o jsonpath='{.items[0].status.phase}' | grep -q Running"
k -n team-a annotate keyvault secrets touch="$(date +%s)" --overwrite >/dev/null
sleep 20
[ "$(vault '.metadata.annotations.crossplane\.io/external-name')" = "$NAME" ] && [ "$(kv '{.status.vaultName}')" = "$NAME" ] && [ "$(k -n team-a get $VAULTS -o name | wc -l)" -eq 1 ] && ok "vault name and pin stable across a function-kro restart" || die "name changed after restart"

# flip private -> public: the endpoint goes away, public access on, firewall Deny + ipRules
k -n team-a patch keyvault secrets --type merge -p '{"spec":{"parameters":{"networking":"public","allowedIpRanges":["203.0.113.0/24"]}}}' >/dev/null
wait_for "private -> public: vault public with the allowlist" 90 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $VAULTS -o jsonpath='{.items[0].spec.forProvider.publicNetworkAccessEnabled}')\" = true ] && [ \"\$(kubectl --context $CTX -n team-a get $VAULTS -o jsonpath='{.items[0].spec.forProvider.networkAcls.ipRules[0]}')\" = 203.0.113.0/24 ]"
[ "$(vault '.spec.forProvider.networkAcls.defaultAction')" = Deny ] && ok "firewall still defaults to Deny" || die "defaultAction"
wait_for "private -> public: private endpoint removed" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get $PES -o name | wc -l) -eq 0 ]"
[ "$(vault '.metadata.annotations.crossplane\.io/external-name')" = "$NAME" ] && ok "same vault after the flip" || die "name changed after flip"

# flip public -> private: the endpoint returns (the subnet is pinned), ipRules empty
k -n team-a patch keyvault secrets --type merge -p '{"spec":{"parameters":{"networking":"private","allowedIpRanges":null}}}' >/dev/null
wait_for "public -> private: vault private again" 90 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $VAULTS -o jsonpath='{.items[0].spec.forProvider.publicNetworkAccessEnabled}')\" = false ] && [ \"\$(kubectl --context $CTX -n team-a get $VAULTS -o jsonpath='{.items[0].spec.forProvider.networkAcls.ipRules}' | tr -d '[]')\" = '' ]"
wait_for "public -> private: private endpoint composed again" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get $PES -o name | wc -l) -eq 1 ]"

# deletionPolicy Delete flips the managementPolicies
k -n team-a patch keyvault secrets --type merge -p '{"spec":{"deletionPolicy":"Delete"}}' >/dev/null
wait_for "deletionPolicy Delete gives managementPolicies *" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $VAULTS -o jsonpath='{.items[0].spec.managementPolicies}')\" = '[\"*\"]' ]"

# private without a platform subnet: Fatal, nothing created, not Ready
k apply -f - >/dev/null <<'EOF'
apiVersion: apiextensions.crossplane.io/v1beta1
kind: EnvironmentConfig
metadata: {name: platform-environment}
data:
  location: westeurope
  resourceGroupName: rg-test-default
  tenantId: 11111111-2222-4333-8444-555555555555
EOF
k -n team-a apply -f - >/dev/null <<'EOF'
apiVersion: platform.a5n.io/v1alpha1
kind: KeyVault
metadata: {name: nosubnet}
spec: {}
EOF
wait_for "private without subnetId: Synced=False SubnetNotConfigured" 60 bash -c "kubectl --context $CTX -n team-a get keyvault nosubnet -o jsonpath='{.status.conditions[?(@.type==\"Synced\")].message}' | grep -q SubnetNotConfigured"
[ -z "$(k -n team-a get keyvault nosubnet -o jsonpath='{.status.environment}')" ] && [ "$(k -n team-a get keyvault nosubnet -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != True ] && ok "nothing pinned, not Ready" || die "nosubnet state"
[ "$(k -n team-a get $VAULTS -o name | wc -l)" -eq 1 ] && ok "no second vault created" || die "unexpected vault"
echo "all live checks passed"
