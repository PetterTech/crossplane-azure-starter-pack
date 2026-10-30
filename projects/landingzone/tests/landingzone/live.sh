#!/usr/bin/env bash
# Live check of the LandingZone composition on a throwaway kind cluster with a real Crossplane
# and the pinned functions. No provider runs. The ResourceGroup managed resource uses its real
# provider CRD (the API server validates the composed object); Subscription, VirtualNetwork,
# StorageAccount and KeyVault are stub CRDs that accept anything, and every status is patched by
# hand. The child compositions and their XRDs are covered by their own tests and by run.sh here.
# Only the kind context is used and the cluster is deleted afterwards.
# Needs kind, kubectl, helm, ruby, Docker and network access. Takes several minutes.
set -euo pipefail

cd "$(dirname "$0")/../.."
T=tests/landingzone
CLUSTER=${CLUSTER:-pr13-live}
CTX=kind-$CLUSTER
trap 'kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true' EXIT
k() { kubectl --context "$CTX" "$@"; }
ok() { echo "PASS $1"; }
die() { echo "FAIL $1"; k -n team-a get landingzones.platform.a5n.io,subscriptions.platform.a5n.io,virtualnetworks.platform.a5n.io,storageaccounts.platform.a5n.io,keyvaults.platform.a5n.io,resourcegroups.azure.m.upbound.io 2>&1 | head -30; exit 1; }
wait_for() { # description timeout command...
  local d=$1 t=$2; shift 2
  for _ in $(seq "$t"); do if "$@" >/dev/null 2>&1; then ok "$d"; return; fi; sleep 2; done
  die "$d"
}
LZ=landingzones.platform.a5n.io
SUBS=subscriptions.platform.a5n.io
VNETS=virtualnetworks.platform.a5n.io
SAS=storageaccounts.platform.a5n.io
KVS=keyvaults.platform.a5n.io
RGS=resourcegroups.azure.m.upbound.io
SUBID=eeeeeeee-1111-2222-3333-ffffffffffff
READY='[{"type":"Ready","status":"True","reason":"Available","lastTransitionTime":"2024-01-01T00:00:00Z"}]'
# of <plural> <name> <jsonpath>: a field of a named object; mr <plural> <lz> <jsonpath>: of a composed one
of() { k -n team-a get "$1" "$2" -o jsonpath="$3"; }
mr() { k -n team-a get "$1" -l "crossplane.io/composite=$2" -o jsonpath="{.items[0]$3}"; }
count() { k -n team-a get "$1" -l "crossplane.io/composite=$2" -o name | wc -l | tr -d ' '; }
synced_msg() { of $LZ "$1" '{.status.conditions[?(@.type=="Synced")].message}'; }
stub_status() { k -n team-a patch "$1" "$2" --subresource=status --type merge -p "$3" >/dev/null; }

kind create cluster --name "$CLUSTER" --wait 120s >/dev/null
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm --kube-context "$CTX" install crossplane crossplane-stable/crossplane --version 2.4.3 -n crossplane-system --create-namespace --wait >/dev/null
ok "Crossplane installed"

k apply -f ../../setup/functions.yaml >/dev/null
wait_for "functions healthy" 90 bash -c "[ \$(kubectl --context $CTX get functions -o jsonpath='{range .items[*]}{.status.conditions[?(@.type==\"Healthy\")].status}{\"\\n\"}{end}' | grep -c True) -eq 5 ]"

ruby -ryaml -e 'c = YAML.load_file(ARGV[0]); c["spec"]["conversion"] = { "strategy" => "None" }; puts c.to_yaml' "$T/crds/resourcegroup.yaml" | k apply -f - >/dev/null
for p in "Subscription subscriptions" "VirtualNetwork virtualnetworks" "StorageAccount storageaccounts" "KeyVault keyvaults"; do
  set -- $p
  k apply -f - >/dev/null <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: $2.platform.a5n.io}
spec:
  group: platform.a5n.io
  scope: Namespaced
  names: {kind: $1, plural: $2}
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources: {status: {}}
      schema: {openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}}
EOF
done
k apply -f - >/dev/null <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: live-test-crossplane
  labels: {rbac.crossplane.io/aggregate-to-crossplane: "true"}
rules:
  - apiGroups: [platform.a5n.io]
    resources: [subscriptions, virtualnetworks, storageaccounts, keyvaults]
    verbs: ["*"]
  - apiGroups: [azure.m.upbound.io]
    resources: ["*"]
    verbs: ["*"]
EOF
k apply -f "$T/env.yaml" >/dev/null
k apply -f apis/landingzone/definition.yaml >/dev/null
k apply -f apis/landingzone/composition.yaml >/dev/null
wait_for "XRD established" 60 k wait --for=condition=Established xrd/landingzones.platform.a5n.io --timeout=1s
k create namespace team-a >/dev/null

# --- a landing zone with everything --------------------------------------------------------
k -n team-a apply -f - >/dev/null <<'EOF'
apiVersion: platform.a5n.io/v1alpha1
kind: LandingZone
metadata: {name: webshop}
spec:
  parameters:
    workload: DevTest
    network: {size: small}
    storageAccount: {containers: [{name: raw}]}
    keyVault: {}
    tags: {costCenter: "0000"}
EOF
wait_for "the Subscription XR is composed, named like the landing zone" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get $SUBS webshop -o jsonpath='{.spec.workload}') = DevTest ]"
[ "$(of $SUBS webshop '{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].controller}')" = LandingZone/true ] && [ "$(of $SUBS webshop '{.metadata.ownerReferences[0].uid}')" = "$(of $LZ webshop '{.metadata.uid}')" ] && ok "the Subscription is controlled by the landing zone (ownerReference with its uid)" || die "Subscription ownerReference"
sleep 10
[ "$(count $RGS webshop)" -eq 0 ] && [ "$(count $VNETS webshop)" -eq 0 ] && [ "$(of $LZ webshop '{.status.subscription}')" = "" ] && ok "nothing else is composed, nothing pinned, until the Subscription is Ready" || die "composed too early"
[ "$(of $LZ webshop '{.status.conditions[?(@.type=="SubscriptionResolved")].reason}')" = SubscriptionPending ] && ok "SubscriptionResolved=False SubscriptionPending" || die "SubscriptionResolved condition"

stub_status $SUBS webshop "{\"status\":{\"subscriptionId\":\"$SUBID\",\"providerConfigName\":\"webshop\",\"conditions\":$READY}}"
wait_for "resolver pinned the Subscription, ProviderConfig name and resource group" 90 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $LZ webshop -o jsonpath='{.status.environment.resourceGroupName}/{.status.providerConfigName}/{.status.subscriptionId}')\" = rg-webshop/webshop/$SUBID ]"
[ "$(of $LZ webshop '{.status.subscriptionUid}')" = "$(of $SUBS webshop '{.metadata.uid}')" ] && ok "the pin carries the Subscription's uid" || die "subscriptionUid pin"
wait_for "resource group MR composed (the real provider CRD accepts it)" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get $RGS -l crossplane.io/composite=webshop -o name | wc -l) -eq 1 ]"
[ "$(mr $RGS webshop '.metadata.annotations.crossplane\.io/external-name')" = rg-webshop ] && [ "$(mr $RGS webshop '.spec.providerConfigRef.name')" = webshop ] && ok "resource group rg-webshop in the new subscription's ProviderConfig" || die "resource group spec"
[ "$(mr $RGS webshop '.spec.managementPolicies')" = '["Create","Observe","Update","LateInitialize"]' ] && ok "resource group: no Delete in managementPolicies" || die "resource group managementPolicies"
[ "$(count $VNETS webshop)" -eq 0 ] && ok "the network waits for the resource group" || die "network composed before the resource group is Ready"

RGMR=$(mr $RGS webshop '.metadata.name')
k -n team-a patch $RGS "$RGMR" --subresource=status --type merge -p "{\"status\":{\"atProvider\":{\"id\":\"/subscriptions/$SUBID/resourceGroups/rg-webshop\",\"location\":\"westeurope\"},\"conditions\":$READY}}" >/dev/null
wait_for "virtual network XR composed in the new subscription" 90 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $VNETS webshop -o jsonpath='{.spec.subscription}/{.spec.parameters.resourceGroupName}/{.spec.parameters.size}')\" = webshop/rg-webshop/small ]"
[ "$(count $SAS webshop)" -eq 0 ] && [ "$(count $KVS webshop)" -eq 0 ] && ok "storage account and key vault wait for the network pin" || die "children composed before the network is pinned"

SUBNET=/subscriptions/$SUBID/resourceGroups/rg-webshop/providers/Microsoft.Network/virtualNetworks/webshop/subnets/snet-default
stub_status $VNETS webshop "{\"status\":{\"subscription\":\"webshop\",\"subscriptionId\":\"$SUBID\",\"subnetId\":\"$SUBNET\",\"conditions\":$READY}}"
wait_for "resolver pinned status.network" 90 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $LZ webshop -o jsonpath='{.status.network.subnetId}')\" = $SUBNET ]"
wait_for "storage account and key vault composed" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get $SAS webshop -o name | wc -l) -eq 1 ] && [ \$(kubectl --context $CTX -n team-a get $KVS webshop -o name | wc -l) -eq 1 ]"
[ "$(of $SAS webshop '{.spec.parameters.privateEndpointSubnetId}/{.spec.parameters.networking}/{.spec.subscription}/{.spec.deletionPolicy}')" = "$SUBNET/private/webshop/Orphan" ] && [ "$(of $KVS webshop '{.spec.parameters.privateEndpointSubnetId}/{.spec.parameters.networking}/{.spec.subscription}/{.spec.deletionPolicy}')" = "$SUBNET/private/webshop/Orphan" ] && ok "children: private, in the landing zone's subnet and subscription, Orphan" || die "children spec"

stub_status $SAS webshop "{\"status\":{\"accountName\":\"stwebshop00000000000001\",\"endpoints\":{\"blob\":\"https://stwebshop00000000000001.blob.core.windows.net/\"},\"conditions\":$READY}}"
stub_status $KVS webshop "{\"status\":{\"vaultName\":\"kvwebshop0000000000001\",\"vaultUri\":\"https://kvwebshop0000000000001.vault.azure.net/\",\"conditions\":$READY}}"
wait_for "status projected" 90 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $LZ webshop -o jsonpath='{.status.storageAccountName}/{.status.keyVaultUri}')\" = stwebshop00000000000001/https://kvwebshop0000000000001.vault.azure.net/ ]"
wait_for "landing zone Ready" 90 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $LZ webshop -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True ]"

PINS='{.status.subscriptionUid}/{.status.environment.resourceGroupName}/{.status.network.subnetId}'
BEFORE=$(of $LZ webshop "$PINS")
out=$(k -n team-a patch $LZ webshop --subresource=status --type merge -p '{"status":{"subscription":"other"}}' 2>&1 || true)
if grep -q write-once <<<"$out"; then ok "status.subscription is write-once on a live Crossplane XRD"; else echo "$out"; die "subscription write-once"; fi
PINS_NOW=$(of $LZ webshop "$PINS")
[ "$PINS_NOW" = "$BEFORE" ] && ok "pins unchanged after the rejected write" || die "pins changed"

# function-kro restart: pins, names and composed resources are unchanged
k -n crossplane-system delete pod -l pkg.crossplane.io/function=function-kro >/dev/null
sleep 5
wait_for "function-kro healthy again" 90 bash -c "kubectl --context $CTX get function function-kro -o jsonpath='{.status.conditions[?(@.type==\"Healthy\")].status}' | grep -q True && kubectl --context $CTX -n crossplane-system get pod -l pkg.crossplane.io/function=function-kro -o jsonpath='{.items[0].status.phase}' | grep -q Running"
k -n team-a annotate $LZ webshop touch="$(date +%s)" --overwrite >/dev/null
sleep 20
[ "$(of $LZ webshop "$PINS")" = "$BEFORE" ] && [ "$(count $RGS webshop)" -eq 1 ] && [ "$(count $VNETS webshop)" -eq 1 ] && [ "$(count $SAS webshop)" -eq 1 ] && [ "$(count $KVS webshop)" -eq 1 ] && [ "$(of $SUBS webshop '{.metadata.uid}')" = "$(of $LZ webshop '{.status.subscriptionUid}')" ] && ok "pins and composed resources stable across a function-kro restart" || die "state changed after restart"

# deletionPolicy Delete (DevTest) maps to the children, never to the resource group or the Subscription
k -n team-a patch $LZ webshop --type merge -p '{"spec":{"deletionPolicy":"Delete"}}' >/dev/null
wait_for "deletionPolicy Delete reaches storage account and key vault" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $SAS webshop -o jsonpath='{.spec.deletionPolicy}')/\$(kubectl --context $CTX -n team-a get $KVS webshop -o jsonpath='{.spec.deletionPolicy}')\" = Delete/Delete ]"
[ "$(mr $RGS webshop '.spec.managementPolicies')" = '["Create","Observe","Update","LateInitialize"]' ] && [ -z "$(of $SUBS webshop '{.spec.deletionPolicy}')" ] && ok "resource group and Subscription never get Delete" || die "Delete leaked to the resource group or Subscription"
k -n team-a patch $LZ webshop --type merge -p '{"spec":{"deletionPolicy":"Orphan"}}' >/dev/null
wait_for "deletionPolicy Orphan flips back" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $SAS webshop -o jsonpath='{.spec.deletionPolicy}')\" = Orphan ]"
out=$(k -n team-a apply -f - 2>&1 <<'EOF' || true
apiVersion: platform.a5n.io/v1alpha1
kind: LandingZone
metadata: {name: prod}
spec:
  deletionPolicy: Delete
EOF
)
if grep -q "Production landing zones are Orphan only" <<<"$out"; then ok "Delete on a Production landing zone is rejected"; else echo "$out"; die "Delete production"; fi

# --- a Subscription of that name that this landing zone does not control: refused (D12) ------
k -n team-a apply -f - >/dev/null <<'EOF'
apiVersion: platform.a5n.io/v1alpha1
kind: Subscription
metadata: {name: foreign}
spec: {workload: Production}
EOF
stub_status $SUBS foreign "{\"status\":{\"subscriptionId\":\"99999999-1111-2222-3333-ffffffffffff\",\"providerConfigName\":\"foreign\",\"conditions\":$READY}}"
k -n team-a apply -f - >/dev/null <<'EOF'
apiVersion: platform.a5n.io/v1alpha1
kind: LandingZone
metadata: {name: foreign}
spec: {}
EOF
wait_for "a Subscription this landing zone does not control: SubscriptionNotControlled" 90 bash -c "kubectl --context $CTX -n team-a get $LZ foreign -o jsonpath='{.status.conditions[?(@.type==\"Synced\")].message}' | grep -q SubscriptionNotControlled"
[ -z "$(of $LZ foreign '{.status.subscription}')" ] && [ "$(count $RGS foreign)" -eq 0 ] && [ "$(of $SUBS foreign '{.spec.workload}')" = Production ] && ok "foreign Subscription untouched, nothing pinned or composed" || die "foreign Subscription state"

# --- an existing virtual network in another subscription: Fatal, nothing created -------------
k -n team-a apply -f - >/dev/null <<'EOF'
apiVersion: platform.a5n.io/v1alpha1
kind: VirtualNetwork
metadata: {name: hub}
spec: {}
EOF
stub_status $VNETS hub "{\"status\":{\"subscription\":\"elsewhere\",\"subscriptionId\":\"88888888-1111-2222-3333-ffffffffffff\",\"subnetId\":\"/subscriptions/88888888-1111-2222-3333-ffffffffffff/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/hub/subnets/snet-default\",\"conditions\":$READY}}"
k -n team-a apply -f - >/dev/null <<'EOF'
apiVersion: platform.a5n.io/v1alpha1
kind: LandingZone
metadata: {name: spoke}
spec:
  virtualNetwork: hub
  parameters:
    keyVault: {}
EOF
wait_for "spoke: Subscription composed" 90 bash -c "kubectl --context $CTX -n team-a get $SUBS spoke -o name"
stub_status $SUBS spoke "{\"status\":{\"subscriptionId\":\"77777777-1111-2222-3333-ffffffffffff\",\"providerConfigName\":\"spoke\",\"conditions\":$READY}}"
wait_for "virtual network of another subscription: Fatal VirtualNetworkNotInSubscription" 90 bash -c "kubectl --context $CTX -n team-a get $LZ spoke -o jsonpath='{.status.conditions[?(@.type==\"Synced\")].message}' | grep -q VirtualNetworkNotInSubscription"
[ -z "$(of $LZ spoke '{.status.network}')" ] && [ "$(count $KVS spoke)" -eq 0 ] && ok "nothing pinned, no key vault composed" || die "spoke state"
echo "all live checks passed"
