#!/usr/bin/env bash
# Live check of the ContainerApp composition on a throwaway kind cluster with a real Crossplane
# and the pinned functions. No provider runs: only the provider CRDs are installed (the API server
# validates the composed managed resources against them) and the managed resources' status is
# patched by hand. Only the kind context is used and the cluster is deleted afterwards.
# Needs kind, kubectl, helm, ruby, Docker and network access. Takes several minutes.
#
# networking, ingress-independent subnet injection and zoneRedundant are immutable on the XR, so the
# private (endpoint), public and injected modes are covered by separate XRs, not by a flip.
set -euo pipefail

cd "$(dirname "$0")/../.."
T=tests/containerapp
CLUSTER=${CLUSTER:-pr12-live}
CTX=kind-$CLUSTER
trap 'kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true' EXIT
# the XR and the provider's ContainerApp share a plural, so the XR is addressed by its full name
k() {
  local a=() x
  for x in "$@"; do [ "$x" = containerapp ] && x=containerapps.platform.a5n.io; a+=("$x"); done
  kubectl --context "$CTX" "${a[@]}"
}
ok() { echo "PASS $1"; }
die() { echo "FAIL $1"; k -n team-a get containerapp,environments.containerapp.azure.m.upbound.io,containerapps.containerapp.azure.m.upbound.io,privateendpoints.network.azure.m.upbound.io 2>&1 | head -30; exit 1; }
wait_for() { # description timeout command...
  local d=$1 t=$2; shift 2
  for _ in $(seq "$t"); do if "$@" >/dev/null 2>&1; then ok "$d"; return; fi; sleep 2; done
  die "$d"
}
ENVS=environments.containerapp.azure.m.upbound.io
APPS=containerapps.containerapp.azure.m.upbound.io
PES=privateendpoints.network.azure.m.upbound.io
# mr <plural> <xr> <jsonpath after .items[0]>: a composed resource of one XR
mr() { k -n team-a get "$1" -l "crossplane.io/composite=$2" -o jsonpath="{.items[0]$3}"; }
count() { k -n team-a get "$1" -l "crossplane.io/composite=$2" -o name | wc -l | tr -d ' '; }
xrs() { k -n team-a get containerapp "$1" -o jsonpath="$2"; }
READY='[{"type":"Ready","status":"True","reason":"Available","lastTransitionTime":"2024-01-01T00:00:00Z"}]'
SUBNET_PE=/subscriptions/cccccccc-1111-2222-3333-dddddddddddd/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-pe
SUBNET_APPS=/subscriptions/cccccccc-1111-2222-3333-dddddddddddd/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-apps
IMG=ghcr.io/example/hello-api:1.4.2
# env_ready <xr>: hand-patch the Environment MR to Ready with an id and a default domain
env_ready() {
  local n e
  n=$(mr $ENVS "$1" '.metadata.name'); e=$(mr $ENVS "$1" '.metadata.annotations.crossplane\.io/external-name')
  k -n team-a patch $ENVS "$n" --subresource=status --type merge -p "{\"status\":{\"atProvider\":{\"id\":\"/subscriptions/eeeeeeee-1111-2222-3333-ffffffffffff/resourceGroups/rg-test-default/providers/Microsoft.App/managedEnvironments/$e\",\"defaultDomain\":\"calm-sea-0123.westeurope.azurecontainerapps.io\"},\"conditions\":$READY}}" >/dev/null
}

kind create cluster --name "$CLUSTER" --wait 120s >/dev/null
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm --kube-context "$CTX" install crossplane crossplane-stable/crossplane --version 2.4.3 -n crossplane-system --create-namespace --wait >/dev/null
ok "Crossplane installed"

k apply -f ../../setup/functions.yaml >/dev/null
wait_for "functions healthy" 90 bash -c "[ \$(kubectl --context $CTX get functions -o jsonpath='{range .items[*]}{.status.conditions[?(@.type==\"Healthy\")].status}{\"\\n\"}{end}' | grep -c True) -eq 5 ]"

# provider CRDs without the conversion webhook
for f in environment containerapp privateendpoint; do
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
  - apiGroups: [containerapp.azure.m.upbound.io, network.azure.m.upbound.io]
    resources: ["*"]
    verbs: ["*"]
EOF
k apply -f "$T/env.yaml" >/dev/null
k apply -f apis/containerapp/definition.yaml >/dev/null
k apply -f apis/containerapp/composition.yaml >/dev/null
wait_for "XRD established" 60 k wait --for=condition=Established xrd/containerapps.platform.a5n.io --timeout=1s
k create namespace team-a >/dev/null

k -n team-a apply -f - >/dev/null <<'EOF'
apiVersion: platform.a5n.io/v1alpha1
kind: Subscription
metadata: {name: sub-a}
spec: {}
EOF
k -n team-a patch subscription sub-a --subresource=status --type merge -p "{\"status\":{\"subscriptionId\":\"eeeeeeee-1111-2222-3333-ffffffffffff\",\"conditions\":$READY}}" >/dev/null

# --- private: environment with a private endpoint -------------------------------------------
k -n team-a apply -f - >/dev/null <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: ContainerApp
metadata: {name: api}
spec:
  parameters:
    image: $IMG
    tags: {costCenter: "0000"}
EOF

wait_for "resolver pinned subscription and subnet" 90 bash -c "[ \"\$(kubectl --context $CTX -n team-a get containerapps.platform.a5n.io api -o jsonpath='{.status.environment.subnetId}')\" != '' ]"
wait_for "environment composed and accepted by the provider CRD (workloadProfile list, no identity object)" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get $ENVS -l crossplane.io/composite=api -o name | wc -l) -eq 1 ]"
ENVNAME=$(mr $ENVS api '.metadata.annotations.crossplane\.io/external-name')
[[ $ENVNAME =~ ^ca[a-z0-9]{22}-env$ ]] && ok "derived environment name $ENVNAME" || die "derived environment name $ENVNAME"
[ "$(mr $ENVS api '.spec.forProvider.publicNetworkAccess')" = Disabled ] && [ "$(mr $ENVS api '.spec.forProvider.workloadProfile[0].workloadProfileType')" = Consumption ] && [ "$(mr $ENVS api '.spec.forProvider.internalLoadBalancerEnabled')" = false ] && ok "private: public access Disabled, Consumption workload profile, no infrastructure subnet" || die "environment hardening"
[ -z "$(mr $ENVS api '.spec.forProvider.infrastructureSubnetId')" ] && ok "private path has no subnet injection" || die "unexpected infrastructureSubnetId"
[ "$(mr $ENVS api '.spec.managementPolicies')" = '["Create","Observe","Update","LateInitialize"]' ] && ok "Orphan: no Delete in managementPolicies" || die "managementPolicies"
[ "$(mr $ENVS api '.spec.providerConfigRef.name')" = sub-a ] && ok "ProviderConfig is the Subscription name" || die "providerConfigRef"
wait_for "status.environmentName pinned" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get containerapps.platform.a5n.io api -o jsonpath='{.status.environmentName}')\" = $ENVNAME ]"
[ "$(count $APPS api)" -eq 0 ] && [ "$(count $PES api)" -eq 0 ] && ok "no app and no endpoint before the environment has an ID" || die "composed too early"

out=$(k -n team-a patch containerapp api --subresource=status --type merge -p '{"status":{"environmentName":"other-env"}}' 2>&1 || true)
if grep -q write-once <<<"$out"; then ok "status.environmentName is write-once on a live Crossplane XRD"; else echo "$out"; die "environmentName write-once"; fi
out=$(k -n team-a patch containerapp api --type merge -p '{"spec":{"parameters":{"name":"late-name"}}}' 2>&1 || true)
if grep -q "can't be added, changed or removed" <<<"$out"; then ok "adding spec.parameters.name to an existing app is rejected"; else echo "$out"; die "name add"; fi

# the environment becomes ready: the app and the private endpoint follow
env_ready api
wait_for "app and one private endpoint composed" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get $APPS -l crossplane.io/composite=api -o name | wc -l) -eq 1 ] && [ \$(kubectl --context $CTX -n team-a get $PES -l crossplane.io/composite=api -o name | wc -l) -eq 1 ]"
APPNAME=$(mr $APPS api '.metadata.annotations.crossplane\.io/external-name')
[[ $APPNAME =~ ^ca[a-z0-9]{22}$ ]] && [ "$ENVNAME" = "$APPNAME-env" ] && ok "derived app name $APPNAME, environment is <app>-env" || die "app name $APPNAME"
[ "$(mr $PES api '.spec.forProvider.privateServiceConnection.subresourceNames[0]')" = managedEnvironment ] && ok "endpoint targets the managedEnvironment group" || die "subresource"
[ "$(mr $PES api '.spec.forProvider.subnetId')" = "$SUBNET_PE" ] && ok "endpoint sits in the pinned platform subnet" || die "pe subnet"
[ "$(mr $APPS api '.spec.forProvider.workloadProfileName')" = Consumption ] && [ "$(mr $APPS api '.spec.forProvider.ingress.externalEnabled')" = false ] && [ "$(mr $APPS api '.spec.forProvider.ingress.allowInsecureConnections')" = false ] && ok "app on the Consumption profile, internal ingress, no insecure connections" || die "app spec"
[ "$(mr $APPS api '.spec.forProvider.template.container[0].image')" = "$IMG" ] && ok "image from the XR" || die "image"
wait_for "status.appName pinned" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get containerapps.platform.a5n.io api -o jsonpath='{.status.appName}')\" = $APPNAME ]"
out=$(k -n team-a patch containerapp api --subresource=status --type merge -p '{"status":{"appName":"other"}}' 2>&1 || true)
if grep -q write-once <<<"$out"; then ok "status.appName is write-once on a live Crossplane XRD"; else echo "$out"; die "appName write-once"; fi
[ "$(xrs api '{.status.conditions[?(@.type=="Ready")].status}')" != True ] && ok "XR not Ready while the app is not" || die "ready too early"

APPMR=$(mr $APPS api '.metadata.name')
k -n team-a patch $APPS "$APPMR" --subresource=status --type merge -p "{\"status\":{\"atProvider\":{\"id\":\"/subscriptions/eeeeeeee-1111-2222-3333-ffffffffffff/resourceGroups/rg-test-default/providers/Microsoft.App/containerApps/$APPNAME\",\"ingress\":{\"fqdn\":\"$APPNAME.internal.calm-sea-0123.westeurope.azurecontainerapps.io\"}},\"conditions\":$READY}}" >/dev/null
wait_for "status.resourceId, fqdn and url projected" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get containerapps.platform.a5n.io api -o jsonpath='{.status.url}')\" = https://$APPNAME.internal.calm-sea-0123.westeurope.azurecontainerapps.io ] && [ \"\$(kubectl --context $CTX -n team-a get containerapps.platform.a5n.io api -o jsonpath='{.status.defaultDomain}')\" = calm-sea-0123.westeurope.azurecontainerapps.io ]"

# function-kro restart: the names, the pins and the composed resources are unchanged
k -n crossplane-system delete pod -l pkg.crossplane.io/function=function-kro >/dev/null
sleep 5
wait_for "function-kro healthy again" 90 bash -c "kubectl --context $CTX get function function-kro -o jsonpath='{.status.conditions[?(@.type==\"Healthy\")].status}' | grep -q True && kubectl --context $CTX -n crossplane-system get pod -l pkg.crossplane.io/function=function-kro -o jsonpath='{.items[0].status.phase}' | grep -q Running"
k -n team-a annotate containerapp api touch="$(date +%s)" --overwrite >/dev/null
sleep 20
[ "$(mr $APPS api '.metadata.annotations.crossplane\.io/external-name')" = "$APPNAME" ] && [ "$(mr $ENVS api '.metadata.annotations.crossplane\.io/external-name')" = "$ENVNAME" ] && [ "$(xrs api '{.status.appName}')" = "$APPNAME" ] && [ "$(count $APPS api)" -eq 1 ] && [ "$(count $ENVS api)" -eq 1 ] && ok "names and pins stable across a function-kro restart" || die "names changed after restart"

# deletionPolicy Delete flips the managementPolicies of the environment and the app, and back
k -n team-a patch containerapp api --type merge -p '{"spec":{"deletionPolicy":"Delete"}}' >/dev/null
wait_for "deletionPolicy Delete gives managementPolicies * on environment and app" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $ENVS -l crossplane.io/composite=api -o jsonpath='{.items[0].spec.managementPolicies}')\" = '[\"*\"]' ] && [ \"\$(kubectl --context $CTX -n team-a get $APPS -l crossplane.io/composite=api -o jsonpath='{.items[0].spec.managementPolicies}')\" = '[\"*\"]' ]"
[ "$(mr $PES api '.spec.managementPolicies')" = '["*"]' ] && ok "the endpoint keeps the default policies (deleted with the XR)" || die "pe managementPolicies"
k -n team-a patch containerapp api --type merge -p '{"spec":{"deletionPolicy":"Orphan"}}' >/dev/null
wait_for "deletionPolicy Orphan removes Delete again" 60 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $APPS -l crossplane.io/composite=api -o jsonpath='{.items[0].spec.managementPolicies}')\" = '[\"Create\",\"Observe\",\"Update\",\"LateInitialize\"]' ]"

# --- public: no endpoint, environment public, external ingress ------------------------------
k -n team-a apply -f - >/dev/null <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: ContainerApp
metadata: {name: web}
spec:
  parameters:
    image: $IMG
    networking: public
    ingress: external
    identity: system
EOF
wait_for "public: environment composed" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get $ENVS -l crossplane.io/composite=web -o name | wc -l) -eq 1 ]"
[ "$(mr $ENVS web '.spec.forProvider.publicNetworkAccess')" = Enabled ] && ok "public: environment public access Enabled" || die "public access"
env_ready web
wait_for "public: app composed with a system identity and external ingress" 90 bash -c "[ \"\$(kubectl --context $CTX -n team-a get $APPS -l crossplane.io/composite=web -o jsonpath='{.items[0].spec.forProvider.identity.type}')\" = SystemAssigned ] && [ \"\$(kubectl --context $CTX -n team-a get $APPS -l crossplane.io/composite=web -o jsonpath='{.items[0].spec.forProvider.ingress.externalEnabled}')\" = true ]"
sleep 10
[ "$(count $PES web)" -eq 0 ] && ok "public: no private endpoint" || die "unexpected endpoint (public)"

# --- injected: dedicated subnet, internal load balancer, no endpoint ------------------------
k -n team-a apply -f - >/dev/null <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: ContainerApp
metadata: {name: worker}
spec:
  parameters:
    image: $IMG
    infrastructureSubnetId: $SUBNET_APPS
    zoneRedundant: true
EOF
wait_for "injected: environment composed" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get $ENVS -l crossplane.io/composite=worker -o name | wc -l) -eq 1 ]"
[ "$(mr $ENVS worker '.spec.forProvider.infrastructureSubnetId')" = "$SUBNET_APPS" ] && [ "$(mr $ENVS worker '.spec.forProvider.internalLoadBalancerEnabled')" = true ] && [ "$(mr $ENVS worker '.spec.forProvider.zoneRedundancyEnabled')" = true ] && ok "injected: user subnet, internal load balancer, zone redundant" || die "injected environment"
env_ready worker
wait_for "injected: app composed" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get $APPS -l crossplane.io/composite=worker -o name | wc -l) -eq 1 ]"
sleep 10
[ "$(count $PES worker)" -eq 0 ] && ok "injected: no private endpoint" || die "unexpected endpoint (injected)"

# --- private without a platform subnet: Fatal, nothing created, not Ready --------------------
k apply -f - >/dev/null <<'EOF'
apiVersion: apiextensions.crossplane.io/v1beta1
kind: EnvironmentConfig
metadata: {name: platform-environment}
data:
  location: westeurope
  resourceGroupName: rg-test-default
EOF
k -n team-a apply -f - >/dev/null <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: ContainerApp
metadata: {name: nosubnet}
spec:
  parameters:
    image: $IMG
EOF
wait_for "private without subnetId: Synced=False SubnetNotConfigured" 60 bash -c "kubectl --context $CTX -n team-a get containerapps.platform.a5n.io nosubnet -o jsonpath='{.status.conditions[?(@.type==\"Synced\")].message}' | grep -q SubnetNotConfigured"
[ -z "$(xrs nosubnet '{.status.environment}')" ] && [ "$(xrs nosubnet '{.status.conditions[?(@.type=="Ready")].status}')" != True ] && ok "nothing pinned, not Ready" || die "nosubnet state"
[ "$(count $ENVS nosubnet)" -eq 0 ] && ok "no environment created" || die "unexpected environment"
# an injected app needs no platform subnet
k -n team-a apply -f - >/dev/null <<EOF
apiVersion: platform.a5n.io/v1alpha1
kind: ContainerApp
metadata: {name: worker2}
spec:
  parameters:
    image: $IMG
    infrastructureSubnetId: $SUBNET_APPS
EOF
wait_for "injected without a platform subnet: environment composed" 90 bash -c "[ \$(kubectl --context $CTX -n team-a get $ENVS -l crossplane.io/composite=worker2 -o name | wc -l) -eq 1 ]"
echo "all live checks passed"
