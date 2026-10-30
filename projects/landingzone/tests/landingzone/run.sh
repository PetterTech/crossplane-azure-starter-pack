#!/usr/bin/env bash
# Render tests for the LandingZone composition. Needs the crossplane CLI, ruby and Docker.
# Run from anywhere: projects/landingzone/tests/landingzone/run.sh
# Each stage mimics one reconcile: pinned status and observed resources are fed back in.
#
# crossplane render keeps one in-memory store. function-kro reads the XR itself through an
# externalRef, so the XR must also be passed with -e, and that copy replaces the one render
# injects spec.resourceRefs into. build_required() therefore adds the refs of the observed
# resources to the copy. render also does not apply XRD defaults to the input XR, so the
# fixtures spell out every default. The Subscription and VirtualNetwork objects the resolver
# lists are passed as required resources as well (cluster.yaml, vnet.yaml).
set -euo pipefail

cd "$(dirname "$0")/../.."
T=tests/landingzone
COMP=apis/landingzone/composition.yaml
XRD=apis/landingzone/definition.yaml
FUNCS=../../setup/functions.yaml
SUBXRD=../foundation/apis/subscription/definition.yaml
VNETXRD=../foundation/apis/virtualnetwork/definition.yaml
SAXRD=../services/apis/storageaccount/definition.yaml
KVXRD=../services/apis/keyvault/definition.yaml
WORK=$T/.work
mkdir -p "$WORK/schemas" "$WORK/validate"
trap 'rm -rf "$WORK"' EXIT
ruby "$T/schemas.rb" "$WORK/schemas" "$XRD" "$VNETXRD" "$SAXRD" "$KVXRD" "$SUBXRD"
cp $T/crds/*.yaml "$XRD" "$SUBXRD" "$VNETXRD" "$SAXRD" "$KVXRD" "$WORK/validate/"

# build_required <xr> <env> <cluster files, space separated> <observed files, space separated or empty>
build_required() {
  ruby -ryaml -e '
    xr_file, env, cluster, observed = ARGV
    xr = YAML.load_file(xr_file)
    obs = observed.split.flat_map { |f| YAML.load_stream(File.read(f)).compact }
    xr["spec"]["crossplane"] = { "resourceRefs" => obs.map { |o| { "apiVersion" => o["apiVersion"], "kind" => o["kind"], "name" => o["metadata"]["name"] } } } unless obs.empty?
    File.write(ARGV[4], ([File.read(env)] + cluster.split.map { |f| File.read(f) } + [YAML.dump(xr)]).join("\n---\n"))
    File.write(ARGV[5], obs.map(&:to_yaml).join)
  ' "$1" "$2" "$3" "${4:-}" "$WORK/required.yaml" "$WORK/observed.yaml"
}

# render <xr> [observed files, names relative to the tests directory] [env] [cluster files]
render() {
  local xr=$1 observed="" env=${3:-$T/env.yaml} cluster=${4:-$T/cluster.yaml} f
  for f in ${2:-}; do observed="$observed $T/$f"; done
  build_required "$xr" "$env" "$cluster" "$observed"
  local args=("$xr" "$COMP" "$FUNCS" -x -e "$WORK/required.yaml" -s "$WORK/schemas" --xrd "$XRD")
  [ -n "$observed" ] && args+=(-o "$WORK/observed.yaml")
  crossplane render "${args[@]}"
}

# check <name> <xr> <observed> <ruby assertions> [env] [cluster files]; the rendered docs are
# `docs`, the XR is `xr`, `st` its status, `res` maps composed resource name to the resource,
# `kinds` lists the composed kinds and `cond` finds a condition by type.
check() {
  local name=$1 xr=$2 observed=$3 code=$4
  render "$xr" "$observed" "${5:-}" "${6:-}" >"$WORK/out.yaml"
  if ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV[0])).compact
    xr = docs.shift
    st = xr["status"] || {}
    docs = docs.reject { |d| d["kind"] == "Result" }
    res = docs.to_h { |d| [d["metadata"]["annotations"]["crossplane.io/composition-resource-name"], d] }
    kinds = docs.map { |d| d["kind"] }.sort
    cond = ->(t) { ((st["conditions"] || []).find { |c| c["type"] == t } || {}) }
    '"$code"'
  ' "$WORK/out.yaml"; then echo "PASS $name"; else echo "FAIL $name"; exit 1; fi
}

# must_fail <name> <reason prefix> <xr> [observed] [env] [cluster files]
must_fail() {
  local name=$1 reason=$2 out
  if out=$(render "$3" "${4:-}" "${5:-}" "${6:-}" 2>&1); then echo "FAIL $name: render succeeded"; exit 1; fi
  if grep -q "fatal" <<<"$out" && grep -q "$reason" <<<"$out"; then echo "PASS $name"; else echo "FAIL $name: unexpected error"; echo "$out" | head -5; exit 1; fi
}

# edit <src> <dst> <ruby edit of d>
edit() { ruby -ryaml -e 'd = YAML.load_file(ARGV[0]); '"$3"'; File.write(ARGV[1], d.to_yaml)' "$1" "$2"; }
# edit_all <src> <dst> <ruby edit of each document d>
edit_all() { ruby -ryaml -e 'File.write(ARGV[1], YAML.load_stream(File.read(ARGV[0])).compact.each { |d| '"$3"' }.map(&:to_yaml).join)' "$1" "$2"; }
# envedit <dst> <ruby edit of d>: a copy of env.yaml
envedit() { edit $T/env.yaml "$WORK/$1" "$2"; }

P='d["spec"]["parameters"]'
SUBNET=/subscriptions/eeeeeeee-1111-2222-3333-ffffffffffff/resourceGroups/rg-webshop/providers/Microsoft.Network/virtualNetworks/webshop/subnets/snet-default
TAGS='{ "costCenter" => "0000", "owner" => "platform-team@example.com", "environment" => "sandbox" }'
cat $T/cluster.yaml >"$WORK/cluster-vnet.yaml"; echo --- >>"$WORK/cluster-vnet.yaml"; cat $T/vnet.yaml >>"$WORK/cluster-vnet.yaml"
# the cluster without the landing zone's Subscription
edit_all $T/cluster.yaml "$WORK/cluster-none.yaml" 'd["metadata"]["name"] = "unrelated" if d["metadata"]["name"] == "webshop"' 
ruby -ryaml -e 'File.write(ARGV[1], YAML.load_stream(File.read(ARGV[0])).compact.reject { |d| d["metadata"]["namespace"] == "team-a" }.map(&:to_yaml).join)' $T/cluster.yaml "$WORK/cluster-none.yaml"

# --- reconcile 1: the Subscription does not exist yet ---------------------------------------
check "reconcile 1: only the Subscription is composed, named like the landing zone, workload and tags copied; resolver waits (no pin)" $T/xr.yaml "" '
  abort kinds.inspect unless kinds == %w[Subscription]
  s = res["subscription"]
  abort s.inspect unless s["metadata"]["name"] == "webshop" && s["metadata"]["namespace"] == "team-a"
  abort s["spec"].inspect unless s["spec"] == { "workload" => "DevTest", "tags" => '"$TAGS"' }
  abort st.inspect if st.key?("subscription") || st.key?("environment") || st.key?("network")
  abort cond["SubscriptionResolved"].inspect unless cond["SubscriptionResolved"]["status"] == "False" && cond["SubscriptionResolved"]["reason"] == "SubscriptionPending"' "$T/env.yaml" "$WORK/cluster-none.yaml"

edit $T/xr.yaml "$WORK/xr-min.yaml" 'd["spec"]["parameters"] = {}; d["metadata"]["name"] = "minimal"'
check "minimal landing zone (no parameters): a Production Subscription named after it, nothing else" "$WORK/xr-min.yaml" "" '
  s = res["subscription"]
  abort s.inspect unless kinds == %w[Subscription] && s["metadata"]["name"] == "minimal" && s["spec"] == { "workload" => "Production" }' "$T/env.yaml" "$WORK/cluster-none.yaml"

edit $T/xr.yaml "$WORK/xr-subname.yaml" 'd["spec"]["subscription"] = "webshop-sub"'
check "spec.subscription names the composed Subscription" "$WORK/xr-subname.yaml" "" '
  abort res["subscription"]["metadata"]["name"].inspect unless res["subscription"]["metadata"]["name"] == "webshop-sub"' "$T/env.yaml" "$WORK/cluster-none.yaml"

# --- reconcile 2: the Subscription is Ready: the resolver pins ------------------------------
check "reconcile 2: the resolver pins subscription, ProviderConfig name and environment (rg-<name>); no network yet; nothing else composed" $T/xr.yaml observed-subscription.yaml '
  abort kinds.inspect unless kinds == %w[Subscription]
  abort st.inspect unless st["subscription"] == "webshop" && st["subscriptionUid"] == "4f0c1d2e-0000-4000-8000-00000000000a" && st["subscriptionId"] == "eeeeeeee-1111-2222-3333-ffffffffffff" && st["providerConfigName"] == "webshop"
  abort st["environment"].inspect unless st["environment"] == { "location" => "westeurope", "resourceGroupName" => "rg-webshop" }
  abort st.inspect if st.key?("network")
  abort cond["SubscriptionResolved"].inspect unless cond["SubscriptionResolved"]["status"] == "True"
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "True"
  abort cond["VirtualNetworkResolved"].inspect unless cond["VirtualNetworkResolved"]["status"] == "False" && cond["VirtualNetworkResolved"]["reason"] == "VirtualNetworkNotFound"'

edit $T/xr.yaml "$WORK/xr-overrides.yaml" "$P[\"location\"] = \"northeurope\"; $P[\"resourceGroupName\"] = \"rg-custom\""
check "spec.parameters.location and resourceGroupName override the defaults" "$WORK/xr-overrides.yaml" observed-subscription.yaml '
  abort st["environment"].inspect unless st["environment"] == { "location" => "northeurope", "resourceGroupName" => "rg-custom" }'

# --- reconcile 3: pins seen: the resource group ---------------------------------------------
check "reconcile 3: resource group only (the rest waits for it); never deleted (no Delete policy), tagged, in the new subscription's ProviderConfig" $T/xr-pinned.yaml observed-subscription.yaml '
  abort kinds.inspect unless kinds == %w[ResourceGroup Subscription]
  g = res["resourceGroup"]
  abort g["metadata"]["annotations"]["crossplane.io/external-name"].inspect unless g["metadata"]["annotations"]["crossplane.io/external-name"] == "rg-webshop"
  abort g["spec"]["managementPolicies"].inspect unless g["spec"]["managementPolicies"] == %w[Create Observe Update LateInitialize]
  abort g["spec"]["providerConfigRef"].inspect unless g["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "webshop" }
  abort g["spec"]["forProvider"].inspect unless g["spec"]["forProvider"]["location"] == "northeurope"
  abort g["spec"]["forProvider"]["tags"].inspect unless g["spec"]["forProvider"]["tags"] == { "a5n-namespace" => "team-a", "a5n-owner-xr" => "webshop", "a5n-xr-uid" => "7a1b2c3d-0000-4000-8000-000000000010", "costCenter" => "0000", "owner" => "platform-team@example.com", "environment" => "sandbox" }
  abort "ready too early" if cond["Ready"]["status"] == "True"'

# --- reconcile 4: resource group Ready: the virtual network ---------------------------------
check "reconcile 4: virtual network composed in the new subscription, named like the landing zone, size and hub from the spec" $T/xr-pinned.yaml "observed-subscription.yaml observed-rg.yaml" '
  abort kinds.inspect unless kinds == %w[ResourceGroup Subscription VirtualNetwork]
  v = res["network"]
  abort v["metadata"].inspect unless v["metadata"]["name"] == "webshop" && v["metadata"]["namespace"] == "team-a"
  abort v["spec"].inspect unless v["spec"] == { "subscription" => "webshop", "parameters" => { "location" => "northeurope", "resourceGroupName" => "rg-webshop", "size" => "small", "peerToHub" => true, "createSubnet" => true, "tags" => '"$TAGS"' } }'

# --- reconcile 5: the virtual network has a subnet: the resolver pins status.network --------
check "reconcile 5: the resolver pins status.network once; storage and vault wait for the pin" $T/xr-pinned.yaml "observed-subscription.yaml observed-rg.yaml observed-network.yaml" '
  abort kinds.inspect unless kinds == %w[ResourceGroup Subscription VirtualNetwork]
  abort st["network"].inspect unless st["network"] == { "virtualNetwork" => "webshop", "subnetId" => "'$SUBNET'" }
  abort cond["VirtualNetworkResolved"].inspect unless cond["VirtualNetworkResolved"]["status"] == "True"' "$T/env.yaml" "$WORK/cluster-vnet.yaml"

# --- reconcile 6: network pinned: storage account and key vault -----------------------------
ALL3="observed-subscription.yaml observed-rg.yaml observed-network.yaml"
check "reconcile 6: private storage account and key vault in the landing zone's subnet, same name, own subscription, Orphan" $T/xr-network.yaml "$ALL3" '
  abort kinds.inspect unless kinds == %w[KeyVault ResourceGroup StorageAccount Subscription VirtualNetwork]
  s = res["storage"]
  abort s["metadata"].inspect unless s["metadata"]["name"] == "webshop" && s["metadata"]["namespace"] == "team-a"
  abort s["spec"].inspect unless s["spec"] == { "subscription" => "webshop", "deletionPolicy" => "Orphan", "parameters" => { "location" => "northeurope", "resourceGroupName" => "rg-webshop", "networking" => "private", "privateEndpointSubnetId" => "'$SUBNET'", "replication" => "ZRS", "containers" => [{ "name" => "raw" }, { "name" => "curated" }], "tags" => '"$TAGS"' } }
  k = res["vault"]
  abort k["metadata"].inspect unless k["metadata"]["name"] == "webshop" && k["metadata"]["namespace"] == "team-a"
  abort k["spec"].inspect unless k["spec"] == { "subscription" => "webshop", "deletionPolicy" => "Orphan", "parameters" => { "location" => "northeurope", "resourceGroupName" => "rg-webshop", "networking" => "private", "privateEndpointSubnetId" => "'$SUBNET'", "softDeleteDays" => 30, "tags" => '"$TAGS"' } }
  abort st["network"].inspect unless st["network"]["subnetId"] == "'$SUBNET'"
  abort "ready too early" if cond["Ready"]["status"] == "True"'

# --- reconcile 7: everything Ready ----------------------------------------------------------
ALL="$ALL3 observed-storage.yaml observed-vault.yaml"
check "reconcile 7: status projected, XR Ready, one ProviderConfig per composed MR, no lock" $T/xr-network.yaml "$ALL" '
  abort kinds.inspect unless kinds == %w[KeyVault ResourceGroup StorageAccount Subscription VirtualNetwork]
  abort st.values_at("storageAccountName", "blobEndpoint", "keyVaultName", "keyVaultUri").inspect unless st.values_at("storageAccountName", "blobEndpoint", "keyVaultName", "keyVaultUri") == ["stwebshop00000000000001", "https://stwebshop00000000000001.blob.core.windows.net/", "kvwebshop0000000000001", "https://kvwebshop0000000000001.vault.azure.net/"]
  abort "no ManagementLock allowed" if kinds.any? { |k| k =~ /Lock/ }
  abort "Ready=#{cond["Ready"].inspect}" unless cond["Ready"]["status"] == "True"' "$T/env.yaml" "$WORK/cluster-vnet.yaml"

# the composed objects must validate against the XRDs of the children and the provider CRDs (v2.8.0)
render $T/xr.yaml observed-subscription.yaml >"$WORK/out-2.yaml"
render $T/xr-pinned.yaml "observed-subscription.yaml observed-rg.yaml" >"$WORK/out-4.yaml"
render $T/xr-network.yaml "$ALL" "$T/env.yaml" "$WORK/cluster-vnet.yaml" >"$WORK/out-all.yaml"
for f in out-2 out-4 out-all; do
  ruby -ryaml -e 'puts YAML.load_stream(File.read(ARGV[0])).compact.reject { |d| d["kind"] == "Result" }.drop(1).map(&:to_yaml).join' "$WORK/$f.yaml" >"$WORK/$f-composed.yaml"
  crossplane resource validate "$WORK/validate" "$WORK/$f-composed.yaml" >/dev/null 2>"$WORK/validate.err" || { echo "FAIL $f: composed objects do not validate against the XRDs and provider CRDs"; cat "$WORK/validate.err"; exit 1; }
done
echo "PASS composed Subscription, ResourceGroup, VirtualNetwork, StorageAccount and KeyVault validate against the XRDs and provider CRDs"

# --- variants -------------------------------------------------------------------------------
edit $T/xr-network.yaml "$WORK/xr-delete.yaml" 'd["spec"]["deletionPolicy"] = "Delete"'
check "deletionPolicy Delete maps to storage account and key vault only; the resource group keeps no Delete policy" "$WORK/xr-delete.yaml" "$ALL3" '
  abort res["storage"]["spec"]["deletionPolicy"].inspect unless res["storage"]["spec"]["deletionPolicy"] == "Delete" && res["vault"]["spec"]["deletionPolicy"] == "Delete"
  abort res["resourceGroup"]["spec"]["managementPolicies"].inspect if res["resourceGroup"]["spec"]["managementPolicies"].include?("Delete") || res["resourceGroup"]["spec"]["managementPolicies"].include?("*")
  abort res["subscription"].inspect if res["subscription"]["spec"].key?("deletionPolicy")'

edit $T/xr-network.yaml "$WORK/xr-nostorage.yaml" "$P.delete(\"storageAccount\")"
check "no parameters.storageAccount: only the key vault is composed" "$WORK/xr-nostorage.yaml" "$ALL3" '
  abort kinds.inspect unless kinds == %w[KeyVault ResourceGroup Subscription VirtualNetwork]'
check "storageAccount removed while it exists: it is no longer composed (Crossplane removes it; Orphan keeps the data)" "$WORK/xr-nostorage.yaml" "$ALL" '
  abort kinds.inspect unless kinds == %w[KeyVault ResourceGroup Subscription VirtualNetwork]' "$T/env.yaml" "$WORK/cluster-vnet.yaml"

edit $T/xr-network.yaml "$WORK/xr-noservices.yaml" "$P.delete(\"storageAccount\"); $P.delete(\"keyVault\")"
check "neither storageAccount nor keyVault: subscription, resource group and network only" "$WORK/xr-noservices.yaml" "$ALL3" '
  abort kinds.inspect unless kinds == %w[ResourceGroup Subscription VirtualNetwork]'

edit $T/xr-network.yaml "$WORK/xr-subonly.yaml" "$P.delete(\"network\"); $P.delete(\"storageAccount\"); $P.delete(\"keyVault\"); d[\"status\"].delete(\"network\")"
check "no network, storage or vault: subscription and resource group only" "$WORK/xr-subonly.yaml" "observed-subscription.yaml observed-rg.yaml" '
  abort kinds.inspect unless kinds == %w[ResourceGroup Subscription]
  abort cond["VirtualNetworkResolved"].inspect unless cond["VirtualNetworkResolved"].empty?'

edit $T/xr-network.yaml "$WORK/xr-explicit.yaml" "$P[\"storageAccount\"] = { \"replication\" => \"GZRS\" }; $P[\"keyVault\"] = {}; $P[\"tags\"] = { \"owner\" => \"o\" }"
check "explicit storage replication, default vault soft delete (90), partial tags" "$WORK/xr-explicit.yaml" "$ALL3" '
  p = res["storage"]["spec"]["parameters"]
  abort p.inspect unless p["replication"] == "GZRS" && !p.key?("containers") || p["containers"] == []
  abort res["vault"]["spec"]["parameters"].inspect unless res["vault"]["spec"]["parameters"]["softDeleteDays"] == 90 && res["vault"]["spec"]["parameters"]["tags"] == { "owner" => "o" }'

# an existing virtual network instead of a created one
edit $T/xr-pinned.yaml "$WORK/xr-lookup.yaml" "$P.delete(\"network\"); d[\"spec\"][\"virtualNetwork\"] = \"spoke\""
edit_all $T/vnet.yaml "$WORK/vnet-spoke.yaml" 'd["metadata"]["name"] = "spoke"; d["status"]["subnetId"] = d["status"]["subnetId"].sub("virtualNetworks/webshop", "virtualNetworks/spoke")'
cat $T/cluster.yaml >"$WORK/cluster-spoke.yaml"; echo --- >>"$WORK/cluster-spoke.yaml"; cat "$WORK/vnet-spoke.yaml" >>"$WORK/cluster-spoke.yaml"
check "spec.virtualNetwork: the existing virtual network's subnet is pinned, no VirtualNetwork is composed" "$WORK/xr-lookup.yaml" "observed-subscription.yaml observed-rg.yaml" '
  abort kinds.inspect unless kinds == %w[ResourceGroup Subscription]
  abort st["network"].inspect unless st["network"] == { "virtualNetwork" => "spoke", "subnetId" => "'${SUBNET/virtualNetworks\/webshop/virtualNetworks/spoke}'" }' "$T/env.yaml" "$WORK/cluster-spoke.yaml"
edit "$WORK/xr-lookup.yaml" "$WORK/xr-lookup-pinned.yaml" 'd["status"]["network"] = { "virtualNetwork" => "spoke", "subnetId" => "'${SUBNET/virtualNetworks\/webshop/virtualNetworks/spoke}'" }'
check "spec.virtualNetwork pinned: storage and vault use the pinned subnet" "$WORK/xr-lookup-pinned.yaml" "observed-subscription.yaml observed-rg.yaml" '
  abort kinds.inspect unless kinds == %w[KeyVault ResourceGroup StorageAccount Subscription]
  abort res["storage"]["spec"]["parameters"]["privateEndpointSubnetId"].inspect unless res["storage"]["spec"]["parameters"]["privateEndpointSubnetId"].end_with?("/virtualNetworks/spoke/subnets/snet-default")'

# a pinned network and Subscription win over later changes
check "pinned network survives the virtual network disappearing (pin wins, nothing is deleted)" $T/xr-network.yaml "$ALL" '
  abort kinds.inspect unless kinds == %w[KeyVault ResourceGroup StorageAccount Subscription VirtualNetwork]
  abort st["network"].inspect unless st["network"]["subnetId"] == "'$SUBNET'"' "$T/env.yaml" "$T/cluster.yaml"

# waiting is not failing
edit_all $T/vnet.yaml "$WORK/vnet-nosubnet.yaml" 'd["status"].delete("subnetId")'
cat $T/cluster.yaml >"$WORK/cluster-nosubnet.yaml"; echo --- >>"$WORK/cluster-nosubnet.yaml"; cat "$WORK/vnet-nosubnet.yaml" >>"$WORK/cluster-nosubnet.yaml"
check "virtual network without a subnet yet: VirtualNetworkResolved False VirtualNetworkNotReady, nothing pinned, nothing else composed" $T/xr-pinned.yaml "observed-subscription.yaml observed-rg.yaml observed-network.yaml" '
  abort kinds.inspect unless kinds == %w[ResourceGroup Subscription VirtualNetwork]
  abort st.inspect if st.key?("network")
  abort cond["VirtualNetworkResolved"].inspect unless cond["VirtualNetworkResolved"]["status"] == "False" && cond["VirtualNetworkResolved"]["reason"] == "VirtualNetworkNotReady"' "$T/env.yaml" "$WORK/cluster-nosubnet.yaml"

# --- negatives: the resolver fails closed (Fatal): nothing is composed, nothing is deleted --
edit_all $T/cluster.yaml "$WORK/cluster-foreign.yaml" 'd["metadata"]["ownerReferences"] = [{ "apiVersion" => "platform.a5n.io/v1alpha1", "kind" => "LandingZone", "name" => "other", "uid" => "00000000-0000-4000-8000-0000000000ff", "controller" => true }] if d["metadata"]["name"] == "webshop"'
must_fail "a Subscription of that name controlled by another landing zone is refused" SubscriptionNotControlled $T/xr.yaml "" "$T/env.yaml" "$WORK/cluster-foreign.yaml"
edit_all $T/cluster.yaml "$WORK/cluster-uncontrolled.yaml" 'd["metadata"].delete("ownerReferences") if d["metadata"]["name"] == "webshop"'
must_fail "a Subscription of that name that nobody controls is refused" SubscriptionNotControlled $T/xr.yaml "" "$T/env.yaml" "$WORK/cluster-uncontrolled.yaml"
must_fail "a pinned Subscription that is controlled by another landing zone is refused" SubscriptionNotControlled $T/xr-pinned.yaml "" "$T/env.yaml" "$WORK/cluster-foreign.yaml"
must_fail "pinned, the Subscription is gone" SubscriptionChanged $T/xr-pinned.yaml "" "$T/env.yaml" "$WORK/cluster-none.yaml"
edit_all $T/cluster.yaml "$WORK/cluster-notready.yaml" 'd["status"]["conditions"][0]["status"] = "False" if d["metadata"]["name"] == "webshop"'
must_fail "pinned Subscription not Ready" SubscriptionNotReady $T/xr-pinned.yaml "" "$T/env.yaml" "$WORK/cluster-notready.yaml"
check "unpinned Subscription not Ready yet: a wait, not a failure" $T/xr.yaml "" '
  abort st.inspect if st.key?("subscription")
  abort cond["SubscriptionResolved"].inspect unless cond["SubscriptionResolved"]["status"] == "False"' "$T/env.yaml" "$WORK/cluster-notready.yaml"
edit $T/xr-pinned.yaml "$WORK/xr-uid.yaml" 'd["status"]["subscriptionUid"] = "4f0c1d2e-0000-4000-8000-0000000000ff"'
must_fail "pinned Subscription was recreated (uid differs)" SubscriptionChanged "$WORK/xr-uid.yaml"
edit $T/xr-pinned.yaml "$WORK/xr-id.yaml" 'd["status"]["subscriptionId"] = "88888888-1111-2222-3333-ffffffffffff"'
must_fail "pinned subscriptionId differs from the Subscription" SubscriptionChanged "$WORK/xr-id.yaml"
edit $T/xr-pinned.yaml "$WORK/xr-mismatch.yaml" 'd["spec"]["subscription"] = "other"'
must_fail "spec.subscription differs from the pin" SubscriptionMismatch "$WORK/xr-mismatch.yaml"

edit_all $T/vnet.yaml "$WORK/vnet-foreign.yaml" 'd["status"]["subscriptionId"] = "99999999-1111-2222-3333-ffffffffffff"'
cat $T/cluster.yaml >"$WORK/cluster-vnet-foreign.yaml"; echo --- >>"$WORK/cluster-vnet-foreign.yaml"; cat "$WORK/vnet-foreign.yaml" >>"$WORK/cluster-vnet-foreign.yaml"
must_fail "the virtual network belongs to another subscription: Fatal" VirtualNetworkNotInSubscription $T/xr-pinned.yaml "" "$T/env.yaml" "$WORK/cluster-vnet-foreign.yaml"
edit_all "$WORK/vnet-spoke.yaml" "$WORK/vnet-spoke-foreign.yaml" 'd["status"]["subscriptionId"] = "99999999-1111-2222-3333-ffffffffffff"'
cat $T/cluster.yaml >"$WORK/cluster-spoke-foreign.yaml"; echo --- >>"$WORK/cluster-spoke-foreign.yaml"; cat "$WORK/vnet-spoke-foreign.yaml" >>"$WORK/cluster-spoke-foreign.yaml"
must_fail "spec.virtualNetwork in another subscription: Fatal" VirtualNetworkNotInSubscription "$WORK/xr-lookup.yaml" "" "$T/env.yaml" "$WORK/cluster-spoke-foreign.yaml"
edit_all $T/vnet.yaml "$WORK/vnet-foreign-subnet.yaml" 'd["status"]["subnetId"] = d["status"]["subnetId"].sub("eeeeeeee-1111-2222-3333-ffffffffffff", "99999999-1111-2222-3333-ffffffffffff")'
cat $T/cluster.yaml >"$WORK/cluster-subnet-foreign.yaml"; echo --- >>"$WORK/cluster-subnet-foreign.yaml"; cat "$WORK/vnet-foreign-subnet.yaml" >>"$WORK/cluster-subnet-foreign.yaml"
must_fail "the subnet of the virtual network is in another subscription: Fatal" VirtualNetworkNotInSubscription $T/xr-pinned.yaml "" "$T/env.yaml" "$WORK/cluster-subnet-foreign.yaml"

envedit env-noloc.yaml 'd["data"].delete("location")'
must_fail "missing location in the environment" EnvironmentInvalid $T/xr.yaml observed-subscription.yaml "$WORK/env-noloc.yaml"
envedit env-eastus.yaml 'd["data"]["location"] = "eastus"'
must_fail "location not in allowedLocations" LocationNotAllowed $T/xr.yaml observed-subscription.yaml "$WORK/env-eastus.yaml"
edit $T/xr.yaml "$WORK/xr-eastus.yaml" "$P[\"location\"] = \"eastus\""
must_fail "spec.parameters.location not in allowedLocations" LocationNotAllowed "$WORK/xr-eastus.yaml" observed-subscription.yaml
edit $T/xr.yaml "$WORK/xr-badrg.yaml" "$P[\"resourceGroupName\"] = \"bad rg\""
must_fail "an invalid resource group name" EnvironmentInvalid "$WORK/xr-badrg.yaml" observed-subscription.yaml
check "pinned XR keeps its location when allowedLocations later excludes it" $T/xr-pinned.yaml observed-subscription.yaml '
  abort kinds.inspect unless kinds == %w[ResourceGroup Subscription]' "$WORK/env-eastus.yaml"

# --- XRD CEL (create-time) and the examples ---------------------------------------------------
validate_rejects() { # name pattern ruby-edit
  edit $T/xr.yaml "$WORK/xr-cel.yaml" "$3"
  local out
  out=$(crossplane resource validate "$XRD" "$WORK/xr-cel.yaml" 2>&1 || true)
  if grep -q "$2" <<<"$out"; then echo "PASS XRD rejects $1"; else echo "FAIL XRD accepts $1"; echo "$out" | head -5; exit 1; fi
}
validate_accepts() { # name ruby-edit
  edit $T/xr.yaml "$WORK/xr-ok.yaml" "$2"
  if crossplane resource validate "$XRD" "$WORK/xr-ok.yaml" >/dev/null 2>&1; then echo "PASS XRD accepts $1"; else echo "FAIL XRD rejects $1"; crossplane resource validate "$XRD" "$WORK/xr-ok.yaml" 2>&1 | head -5; exit 1; fi
}
validate_rejects "deletionPolicy Delete with workload Production" "Production landing zones are Orphan only" "d[\"spec\"][\"deletionPolicy\"] = \"Delete\"; $P[\"workload\"] = \"Production\""
validate_rejects "deletionPolicy Delete with no workload" "Production landing zones are Orphan only" "d[\"spec\"][\"deletionPolicy\"] = \"Delete\"; $P.delete(\"workload\")"
validate_rejects "virtualNetwork together with parameters.network" "not both" 'd["spec"]["virtualNetwork"] = "spoke"'
validate_rejects "storageAccount without any network" "need a virtual network" "$P.delete(\"network\")"
validate_rejects "keyVault without any network" "need a virtual network" "$P.delete(\"network\"); $P.delete(\"storageAccount\")"
validate_rejects "the reserved name default" "reserved" 'd["metadata"]["name"] = "default"'
validate_rejects "the reserved platform- prefix" "reserved" 'd["metadata"]["name"] = "platform-lz"'
validate_rejects "a name of 31 characters" "at most 30" 'd["metadata"]["name"] = "a" * 31'
validate_rejects "spec.subscription platform- prefix" "reserved" 'd["spec"]["subscription"] = "platform-x"'
validate_rejects "more than 20 containers" "maxItems\|Too many\|at most 20" "$P[\"storageAccount\"][\"containers\"] = (1..21).map { |i| { \"name\" => \"c#{i}0\" } }"
validate_rejects "more than 10 tags" "Allowed tag keys\|maxProperties\|Too many" "$P[\"tags\"] = (1..11).to_h { |i| [\"k#{i}\", \"v\"] }"
validate_rejects "a tag key outside the allowlist" "Allowed tag keys" "$P[\"tags\"][\"a5n-xr-uid\"] = \"x\""
validate_rejects "an unknown workload" "Unsupported value\|enum" "$P[\"workload\"] = \"Staging\""
validate_rejects "an unknown network size" "Unsupported value\|enum" "$P[\"network\"][\"size\"] = \"huge\""
validate_rejects "soft delete days below 7" "minimum\|greater than or equal" "$P[\"keyVault\"][\"softDeleteDays\"] = 3"
validate_accepts "deletionPolicy Delete with workload DevTest" 'd["spec"]["deletionPolicy"] = "Delete"'
validate_accepts "an existing virtual network instead of parameters.network" "$P.delete(\"network\"); d[\"spec\"][\"virtualNetwork\"] = \"spoke\""
validate_accepts "exactly 20 containers" "$P[\"storageAccount\"][\"containers\"] = (1..20).map { |i| { \"name\" => \"cont#{i}\" } }"
validate_accepts "a subscription named with the maximum 30 characters" 'd["spec"]["subscription"] = "a" * 30'
crossplane resource validate "$XRD" $T/xr.yaml >/dev/null && echo "PASS fixture validates against the XRD" || { echo "FAIL fixture validates against the XRD"; exit 1; }
crossplane resource validate "$XRD" examples/landingzone/landingzone.yaml >/dev/null && echo "PASS examples validate against the XRD" || { echo "FAIL examples validate against the XRD"; exit 1; }
echo "all landingzone render tests passed"
