#!/usr/bin/env bash
# Render tests for the ContainerApp composition. Needs the crossplane CLI, ruby and Docker.
# Run from anywhere: projects/services/tests/containerapp/run.sh
# Each stage mimics one reconcile: pinned status and observed resources are fed back in.
#
# crossplane render keeps one in-memory store. function-kro reads the XR itself through an
# externalRef, so the XR must also be passed with -e, and that copy replaces the one render
# injects spec.resourceRefs into. build_required() therefore adds the refs of the observed
# resources to the copy. render also does not apply XRD defaults to the input XR, so the
# fixtures spell out every default.
set -euo pipefail

cd "$(dirname "$0")/../.."
T=tests/containerapp
COMP=apis/containerapp/composition.yaml
XRD=apis/containerapp/definition.yaml
FUNCS=../../setup/functions.yaml
WORK=$T/.work
mkdir -p "$WORK/schemas"
trap 'rm -rf "$WORK"' EXIT
ruby "$T/schemas.rb" "$WORK/schemas" "$XRD"

# build_required <xr> <env> <subscriptions> <observed or empty> -> $WORK/required.yaml
build_required() {
  ruby -ryaml -e '
    xr_file, env, subs, observed = ARGV
    xr = YAML.load_file(xr_file)
    if !observed.empty?
      refs = YAML.load_stream(File.read(observed)).compact.map { |o| { "apiVersion" => o["apiVersion"], "kind" => o["kind"], "name" => o["metadata"]["name"] } }
      xr["spec"]["crossplane"] = { "resourceRefs" => refs }
    end
    File.write(ARGV[4], [File.read(env), File.read(subs), YAML.dump(xr)].join("\n---\n"))
  ' "$1" "$2" "$3" "${4:-}" "$WORK/required.yaml"
}

# render <xr> [observed] [env] [subscriptions]; paths are relative to the tests directory or $WORK.
render() {
  local xr=$1 observed=${2:-} env=${3:-$T/env.yaml} subs=${4:-$T/subscriptions.yaml}
  [ -n "$observed" ] && observed="$T/$observed"
  build_required "$xr" "$env" "$subs" "$observed"
  local args=("$xr" "$COMP" "$FUNCS" -x -e "$WORK/required.yaml" -s "$WORK/schemas" --xrd "$XRD")
  [ -n "$observed" ] && args+=(-o "$observed")
  crossplane render "${args[@]}"
}

# check <name> <xr> <observed> <ruby assertions> [env] [subscriptions]; the rendered docs are
# `docs`, the XR is `xr`, `st` its status, `res` maps composed resource name to the resource,
# `kinds` lists the composed kinds and `cond` finds a condition by type.
check() {
  local name=$1 xr=$2 observed=$3 code=$4
  render "$xr" "$observed" "${5:-}" "${6:-}" >"$WORK/out.yaml"
  if ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV[0])).compact
    xr = docs.shift
    st = xr["status"]
    docs = docs.reject { |d| d["kind"] == "Result" }
    res = docs.to_h { |d| [d["metadata"]["annotations"]["crossplane.io/composition-resource-name"], d] }
    kinds = docs.map { |d| d["kind"] }.sort
    cond = ->(t) { (st["conditions"].find { |c| c["type"] == t } || {}) }
    '"$code"'
  ' "$WORK/out.yaml"; then echo "PASS $name"; else echo "FAIL $name"; exit 1; fi
}

# must_fail <name> <reason prefix> <xr> [observed] [env] [subscriptions]
must_fail() {
  local name=$1 reason=$2 out
  if out=$(render "$3" "${4:-}" "${5:-}" "${6:-}" 2>&1); then echo "FAIL $name: render succeeded"; exit 1; fi
  if grep -q "fatal" <<<"$out" && grep -q "$reason" <<<"$out"; then echo "PASS $name"; else echo "FAIL $name: unexpected error"; echo "$out" | head -5; exit 1; fi
}

# edit <src> <dst> <ruby edit of d>
edit() { ruby -ryaml -e 'd = YAML.load_file(ARGV[0]); '"$3"'; File.write(ARGV[1], d.to_yaml)' "$1" "$2"; }

# envedit <dst> <ruby edit of d>: a copy of env.yaml
envedit() { edit $T/env.yaml "$WORK/$1" "$2"; }

# name_of <rendered file> <kind>: the external-name of the first resource of that kind
name_of() { ruby -ryaml -e 'puts YAML.load_stream(File.read(ARGV[0])).find { |d| d["kind"] == ARGV[1] }["metadata"]["annotations"]["crossplane.io/external-name"]' "$1" "$2"; }

cat $T/subscriptions.yaml >"$WORK/subs-two.yaml"; echo --- >>"$WORK/subs-two.yaml"; cat $T/subscription-b.yaml >>"$WORK/subs-two.yaml"

PINNED_ID=4f0c1d2e-0000-4000-8000-00000000000a
SUBNET=/subscriptions/cccccccc-1111-2222-3333-dddddddddddd/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-pe
INJECTED=/subscriptions/cccccccc-1111-2222-3333-dddddddddddd/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-apps
P='d["spec"]["parameters"]'

# --- reconcile 1: nothing pinned yet -------------------------------------------------------
check "reconcile 1: resolver pins subscription and environment incl. subnetId; nothing composed" $T/xr.yaml "" '
  abort kinds.inspect unless kinds.empty?
  abort st.inspect unless st["subscription"] == "sub-a" && st["subscriptionUid"] == "'$PINNED_ID'" && st["subscriptionId"] == "eeeeeeee-1111-2222-3333-ffffffffffff"
  abort st["environment"].inspect unless st["environment"] == { "location" => "westeurope", "resourceGroupName" => "rg-test-default", "subnetId" => "'$SUBNET'" }
  abort cond["SubscriptionResolved"].inspect unless cond["SubscriptionResolved"]["status"] == "True"
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "True"
  abort cond["EnvironmentDrift"].inspect unless cond["EnvironmentDrift"]["status"] == "False"'

edit $T/xr.yaml "$WORK/xr-sub-b.yaml" 'd["spec"]["subscription"] = "sub-b"'
check "spec.subscription selects one of two Ready Subscriptions" "$WORK/xr-sub-b.yaml" "" '
  abort st.inspect unless st["subscription"] == "sub-b" && st["subscriptionId"] == "99999999-1111-2222-3333-ffffffffffff"
  abort cond["SubscriptionResolved"]["message"] unless cond["SubscriptionResolved"]["message"].include?("spec.subscription")' "$T/env.yaml" "$WORK/subs-two.yaml"

edit $T/xr.yaml "$WORK/xr-injected1.yaml" "$P[\"infrastructureSubnetId\"] = \"$INJECTED\""
envedit env-nosubnet.yaml 'd["data"].delete("subnetId")'
check "reconcile 1, injected: no platform subnet needed, EnvironmentValid stays True" "$WORK/xr-injected1.yaml" "" '
  abort st["environment"].inspect unless st["environment"] == { "location" => "westeurope", "resourceGroupName" => "rg-test-default" }
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "True"' "$WORK/env-nosubnet.yaml"

# --- reconcile 2: pins fed back in ---------------------------------------------------------
check "reconcile 2: only the environment (app and endpoint wait for its ID); pins win; hardened" $T/xr-pinned.yaml "" '
  abort kinds.inspect unless kinds == %w[Environment]
  e = res["environment"]
  f = e["spec"]["forProvider"]
  abort f.inspect unless f.values_at("location", "resourceGroupName") == ["northeurope", "rg-pinned"]
  abort f.inspect unless f["publicNetworkAccess"] == "Disabled" && f["internalLoadBalancerEnabled"] == false && f["zoneRedundancyEnabled"] == false
  abort f["workloadProfile"].inspect unless f["workloadProfile"] == [{ "name" => "Consumption", "workloadProfileType" => "Consumption" }]
  abort "no subnet injection on the private endpoint path" if f.key?("infrastructureSubnetId")
  abort "no log destination" if f.key?("logsDestination") || f.key?("logAnalyticsWorkspaceId")
  abort e["spec"]["providerConfigRef"].inspect unless e["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "sub-a" }
  abort e["spec"]["managementPolicies"].inspect unless e["spec"]["managementPolicies"] == %w[Create Observe Update LateInitialize]
  an = e["metadata"]["annotations"]["crossplane.io/external-name"]
  abort an unless an =~ /\Aca[a-z0-9]{22}-env\z/
  abort f["tags"].inspect unless f["tags"] == { "a5n-namespace" => "team-a", "a5n-owner-xr" => "api", "a5n-xr-uid" => "7a1b2c3d-0000-4000-8000-000000000004", "costCenter" => "0000", "owner" => "platform-team@example.com", "environment" => "sandbox" }
  abort cond["EnvironmentDrift"].inspect unless cond["EnvironmentDrift"]["status"] == "True" && cond["EnvironmentDrift"]["reason"] == "EnvironmentChanged"
  abort "ready too early" if cond["Ready"]["status"] == "True"'

# the derived name: deterministic, depends on the Subscription and on the XR name (adoption by name),
# 24 lowercase alphanumerics starting with a letter; the environment is named <app>-env
render $T/xr-pinned.yaml observed-env.yaml >"$WORK/name1.yaml"; render $T/xr-pinned.yaml >"$WORK/name2.yaml"
edit $T/xr-pinned.yaml "$WORK/xr-other-sub.yaml" 'd["spec"]["subscription"] = "sub-b"; d["status"]["subscription"] = "sub-b"; d["status"]["subscriptionUid"] = "4f0c1d2e-0000-4000-8000-00000000000b"; d["status"]["subscriptionId"] = "99999999-1111-2222-3333-ffffffffffff"'
render "$WORK/xr-other-sub.yaml" "" "$T/env.yaml" "$WORK/subs-two.yaml" >"$WORK/name3.yaml"
edit $T/xr-pinned.yaml "$WORK/xr-other-name.yaml" 'd["metadata"]["name"] = "other"'
render "$WORK/xr-other-name.yaml" >"$WORK/name4.yaml"
render $T/xr-pinned.yaml >"$WORK/name5.yaml"
ruby -ryaml -e '
  load_name = ->(f, k) { YAML.load_stream(File.read(f)).find { |d| d["kind"] == k }["metadata"]["annotations"]["crossplane.io/external-name"] }
  envs = ARGV[1..].map { |f| load_name.(f, "Environment") }
  abort envs.inspect unless envs[0] == envs[1] && envs[0] != envs[2] && envs[0] != envs[3] && envs[2] != envs[3]
  abort envs.inspect unless envs.all? { |x| x =~ /\Aca[a-z0-9]{22}-env\z/ }
  app = load_name.(ARGV[0], "ContainerApp")
  abort app.inspect unless app =~ /\A[a-z][a-z0-9]{23}\z/' "$WORK/name1.yaml" "$WORK/name5.yaml" "$WORK/name2.yaml" "$WORK/name3.yaml" "$WORK/name4.yaml" \
  && echo "PASS derived names: deterministic, app 24 chars lowercase alphanumeric, environment <app>-env, differ per Subscription and per XR name"

# pinned status names win over the derived name and over a spec.parameters.name added later
edit $T/xr-pinned.yaml "$WORK/xr-name-pinned.yaml" 'd["status"]["appName"] = "pinned-app-01"; d["status"]["environmentName"] = "pinned-env-01"'
check "pinned status.appName and status.environmentName win over the derived names" "$WORK/xr-name-pinned.yaml" observed-env.yaml '
  abort res["environment"]["metadata"]["annotations"].inspect unless res["environment"]["metadata"]["annotations"]["crossplane.io/external-name"] == "pinned-env-01"
  abort res["app"]["metadata"]["annotations"].inspect unless res["app"]["metadata"]["annotations"]["crossplane.io/external-name"] == "pinned-app-01"'
edit "$WORK/xr-name-pinned.yaml" "$WORK/xr-name-both.yaml" "$P[\"name\"] = \"my-api-01\""
check "pinned names win over a spec.parameters.name added later (no second app)" "$WORK/xr-name-both.yaml" observed-env.yaml '
  abort res["app"]["metadata"]["annotations"].inspect unless res["app"]["metadata"]["annotations"]["crossplane.io/external-name"] == "pinned-app-01"
  abort res["environment"]["metadata"]["annotations"].inspect unless res["environment"]["metadata"]["annotations"]["crossplane.io/external-name"] == "pinned-env-01"'

# deletionPolicy: Orphan leaves no Delete in managementPolicies
edit $T/xr-pinned.yaml "$WORK/xr-delete.yaml" 'd["spec"]["deletionPolicy"] = "Delete"'
check "deletionPolicy Delete: environment and app manage everything, the endpoint has no policy override" "$WORK/xr-delete.yaml" observed-env.yaml '
  abort res["environment"]["spec"]["managementPolicies"].inspect unless res["environment"]["spec"]["managementPolicies"] == ["*"]
  abort res["app"]["spec"]["managementPolicies"].inspect unless res["app"]["spec"]["managementPolicies"] == ["*"]
  abort res["privateEndpoint"]["spec"].key?("managementPolicies").inspect if res["privateEndpoint"]["spec"].key?("managementPolicies")'

# --- reconcile 3: environment Ready --------------------------------------------------------
check "reconcile 3: app and private endpoint follow the environment; status projected" $T/xr-pinned.yaml observed-env.yaml '
  abort kinds.inspect unless kinds == %w[ContainerApp Environment PrivateEndpoint]
  abort st.inspect unless st["environmentName"] == "fixedapp01-env" && st["environmentId"].end_with?("/managedEnvironments/fixedapp01-env") && st["defaultDomain"] == "calm-sea-0123.northeurope.azurecontainerapps.io"
  abort "no app status yet" if st.key?("resourceId") || st.key?("fqdn") || st.key?("url") || st.key?("privateEndpointId")
  a = res["app"]
  f = a["spec"]["forProvider"]
  abort f.inspect unless f["containerAppEnvironmentId"] == st["environmentId"] && f["resourceGroupName"] == "rg-pinned" && f["workloadProfileName"] == "Consumption" && f["revisionMode"] == "Single"
  abort f["ingress"].inspect unless f["ingress"] == { "externalEnabled" => false, "targetPort" => 8080, "allowInsecureConnections" => false, "transport" => "auto", "trafficWeight" => [{ "latestRevision" => true, "percentage" => 100 }] }
  abort f["template"].inspect unless f["template"] == { "minReplicas" => 1, "maxReplicas" => 3, "httpScaleRule" => [{ "name" => "http", "concurrentRequests" => "50" }], "container" => [{ "name" => "app", "image" => "ghcr.io/example/hello-api:1.4.2", "cpu" => 0.25, "memory" => "0.5Gi" }] }
  abort "no identity when none" if f.key?("identity")
  abort a["spec"]["providerConfigRef"].inspect unless a["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "sub-a" }
  abort a["spec"]["managementPolicies"].inspect unless a["spec"]["managementPolicies"] == %w[Create Observe Update LateInitialize]
  abort a["metadata"]["annotations"]["crossplane.io/external-name"] unless a["metadata"]["annotations"]["crossplane.io/external-name"] =~ /\Aca[a-z0-9]{22}\z/
  pe = res["privateEndpoint"]
  p = pe["spec"]["forProvider"]
  abort p.inspect unless p["subnetId"] == st["environment"]["subnetId"] && p["location"] == "northeurope" && p["resourceGroupName"] == "rg-pinned"
  abort p["privateServiceConnection"].inspect unless p["privateServiceConnection"] == { "name" => "containerapp", "isManualConnection" => false, "privateConnectionResourceId" => st["environmentId"], "subresourceNames" => ["managedEnvironment"] }
  abort p.keys.inspect if p.key?("privateDnsZoneGroup")
  abort pe["spec"]["providerConfigRef"].inspect unless pe["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "sub-a" }
  abort pe["metadata"]["annotations"].inspect unless pe["metadata"]["annotations"]["crossplane.io/external-name"] == "fixedapp01-env-pe"
  abort "ready too early" if cond["Ready"]["status"] == "True"'

# --- reconcile 4: everything Ready ---------------------------------------------------------
check "reconcile 4: app and endpoint projected, XR Ready, one ProviderConfig, no lock, no role assignment, no DNS zone group" $T/xr-pinned.yaml observed-all.yaml '
  abort kinds.inspect unless kinds == %w[ContainerApp Environment PrivateEndpoint]
  abort st.inspect unless st["appName"] == "fixedapp01" && st["environmentName"] == "fixedapp01-env"
  abort st.inspect unless st["resourceId"].end_with?("/containerApps/fixedapp01") && st["fqdn"] == "fixedapp01.internal.calm-sea-0123.northeurope.azurecontainerapps.io" && st["url"] == "https://" + st["fqdn"]
  abort st.inspect unless st["privateEndpointId"].end_with?("/privateEndpoints/fixedapp01-env-pe")
  abort "no ManagementLock or RoleAssignment allowed" if kinds.any? { |k| k =~ /Lock|RoleAssignment/ }
  abort docs.map { |d| d["spec"]["providerConfigRef"] }.uniq.inspect unless docs.all? { |d| d["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "sub-a" } }
  abort "Ready=#{cond["Ready"].inspect}" unless cond["Ready"]["status"] == "True"'

# variants: public with external ingress, injected with an internal load balancer, system identity, sizes
edit $T/xr-pinned.yaml "$WORK/xr-public.yaml" "$P[\"networking\"] = \"public\"; $P[\"ingress\"] = \"external\"; $P[\"identity\"] = \"system\"; $P[\"size\"] = \"large\"; $P[\"minReplicas\"] = 0; d[\"status\"][\"environment\"].delete(\"subnetId\")"
check "public, external ingress, system identity, large: no endpoint, environment public, no subnet needed" "$WORK/xr-public.yaml" observed-env.yaml '
  abort kinds.inspect unless kinds == %w[ContainerApp Environment]
  f = res["environment"]["spec"]["forProvider"]
  abort f.inspect unless f["publicNetworkAccess"] == "Enabled" && f["internalLoadBalancerEnabled"] == false && !f.key?("infrastructureSubnetId")
  a = res["app"]["spec"]["forProvider"]
  abort a["ingress"].inspect unless a["ingress"]["externalEnabled"] == true && a["ingress"]["allowInsecureConnections"] == false
  abort a["identity"].inspect unless a["identity"] == { "type" => "SystemAssigned" }
  abort a["template"].inspect unless a["template"]["minReplicas"] == 0 && a["template"]["container"][0].values_at("cpu", "memory") == [1.0, "2Gi"]
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "True"'

edit "$WORK/xr-public.yaml" "$WORK/xr-medium.yaml" "$P[\"size\"] = \"medium\""
check "size medium: 0.5 CPU, 1Gi" "$WORK/xr-medium.yaml" observed-env.yaml '
  abort res["app"]["spec"]["forProvider"]["template"]["container"][0].inspect unless res["app"]["spec"]["forProvider"]["template"]["container"][0].values_at("cpu", "memory") == [0.5, "1Gi"]'

edit $T/xr-pinned.yaml "$WORK/xr-injected.yaml" "$P[\"infrastructureSubnetId\"] = \"$INJECTED\"; $P[\"zoneRedundant\"] = true; d[\"status\"][\"environment\"].delete(\"subnetId\")"
check "injected, internal ingress, zone redundant: environment in the user subnet with an internal load balancer, no endpoint" "$WORK/xr-injected.yaml" observed-env.yaml '
  abort kinds.inspect unless kinds == %w[ContainerApp Environment]
  f = res["environment"]["spec"]["forProvider"]
  abort f.inspect unless f["infrastructureSubnetId"] == "'$INJECTED'" && f["internalLoadBalancerEnabled"] == true && f["zoneRedundancyEnabled"] == true && f["publicNetworkAccess"] == "Disabled"
  abort f["workloadProfile"].inspect unless f["workloadProfile"] == [{ "name" => "Consumption", "workloadProfileType" => "Consumption" }]
  abort st.inspect if st.key?("privateEndpointId")
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "True"'

edit "$WORK/xr-injected.yaml" "$WORK/xr-injected-ext.yaml" "$P[\"networking\"] = \"public\"; $P[\"ingress\"] = \"external\""
check "injected, public network, external ingress: environment public, no internal load balancer" "$WORK/xr-injected-ext.yaml" observed-env.yaml '
  f = res["environment"]["spec"]["forProvider"]
  abort f.inspect unless f["publicNetworkAccess"] == "Enabled" && f["internalLoadBalancerEnabled"] == false && f["infrastructureSubnetId"] == "'$INJECTED'"'

# the composed managed resources must validate against the provider CRDs (v2.8.0): objects versus lists
render $T/xr-pinned.yaml >"$WORK/out-2.yaml"
render $T/xr-pinned.yaml observed-env.yaml >"$WORK/out-3.yaml"
render $T/xr-pinned.yaml observed-all.yaml >"$WORK/out-all.yaml"
render "$WORK/xr-public.yaml" observed-env.yaml >"$WORK/out-public.yaml"
render "$WORK/xr-injected.yaml" observed-env.yaml >"$WORK/out-injected.yaml"
for f in out-2 out-3 out-all out-public out-injected; do
  ruby -ryaml -e 'puts YAML.load_stream(File.read(ARGV[0])).compact.select { |d| d["apiVersion"] =~ /azure\.m\.upbound\.io/ }.map(&:to_yaml).join' "$WORK/$f.yaml" >"$WORK/$f-mrs.yaml"
  crossplane resource validate $T/crds "$WORK/$f-mrs.yaml" >/dev/null 2>"$WORK/validate.err" || { echo "FAIL $f: managed resources do not validate against the provider CRDs"; cat "$WORK/validate.err"; exit 1; }
done
echo "PASS composed Environment, ContainerApp and PrivateEndpoint validate against the provider CRDs"

# --- private without a usable subnet and without an own infrastructure subnet: fail closed ---
envedit env-placeholder.yaml 'd["data"]["subnetId"] = "<SUBNET_ID>"'
envedit env-badsubnet.yaml 'd["data"]["subnetId"] = "not-a-subnet"'
for e in env-nosubnet env-placeholder env-badsubnet; do
  must_fail "private, first reconcile, $e: Fatal SubnetNotConfigured, nothing pinned or composed, Ready not reported" SubnetNotConfigured $T/xr.yaml "" "$WORK/$e.yaml"
  edit $T/xr-pinned.yaml "$WORK/xr-held.yaml" 'd["status"].delete("environment")'
  must_fail "private, no pinned environment ($e): still Fatal on the next reconcile" SubnetNotConfigured "$WORK/xr-held.yaml" "" "$WORK/$e.yaml"
done

edit $T/xr-pinned.yaml "$WORK/xr-flip.yaml" 'd["status"]["environment"].delete("subnetId")'
check "pinned without a subnetId but private: no endpoint, EnvironmentValid=False SubnetNotConfigured, environment stays" "$WORK/xr-flip.yaml" observed-env.yaml '
  abort kinds.inspect unless kinds == %w[ContainerApp Environment]
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "False" && cond["EnvironmentValid"]["reason"] == "SubnetNotConfigured"' "$T/env.yaml"

check "subnetId removed from the environment later: a pinned app keeps its endpoint, drift reported" $T/xr-pinned.yaml observed-env.yaml '
  abort kinds.include?("PrivateEndpoint").inspect unless kinds.include?("PrivateEndpoint")
  abort cond["EnvironmentDrift"]["message"].inspect unless cond["EnvironmentDrift"]["message"].include?("subnetId")' "$WORK/env-nosubnet.yaml"

# --- negatives: the resolver fails closed (Fatal): nothing is composed, nothing is deleted --
ruby -ryaml -e 'File.write(ARGV[1], YAML.load_stream(File.read(ARGV[0])).reject { |d| d["metadata"]["namespace"] == "team-a" }.map(&:to_yaml).join)' $T/subscriptions.yaml "$WORK/subs-none.yaml"
must_fail "no Subscription in the namespace" SubscriptionNotFound $T/xr.yaml "" "$T/env.yaml" "$WORK/subs-none.yaml"
must_fail "no Subscription, pinned XR" SubscriptionChanged $T/xr-pinned.yaml "" "$T/env.yaml" "$WORK/subs-none.yaml"

must_fail "two Ready Subscriptions and no spec.subscription" SubscriptionAmbiguous $T/xr.yaml "" "$T/env.yaml" "$WORK/subs-two.yaml"

ruby -ryaml -e 'File.write(ARGV[1], YAML.load_stream(File.read(ARGV[0])).each { |d| d["status"]["conditions"][0]["status"] = "False" if d["metadata"]["name"] == "sub-a" }.map(&:to_yaml).join)' $T/subscriptions.yaml "$WORK/subs-notready.yaml"
must_fail "Subscription not Ready" SubscriptionNotReady $T/xr.yaml "" "$T/env.yaml" "$WORK/subs-notready.yaml"
must_fail "pinned Subscription not Ready" SubscriptionNotReady $T/xr-pinned.yaml "" "$T/env.yaml" "$WORK/subs-notready.yaml"

edit $T/xr-pinned.yaml "$WORK/xr-mismatch.yaml" 'd["spec"]["subscription"] = "sub-b"'
must_fail "spec.subscription differs from the pin" SubscriptionMismatch "$WORK/xr-mismatch.yaml" "" "$T/env.yaml" "$WORK/subs-two.yaml"

edit $T/xr-pinned.yaml "$WORK/xr-uid.yaml" 'd["status"]["subscriptionUid"] = "4f0c1d2e-0000-4000-8000-0000000000ff"'
must_fail "pinned Subscription was recreated (uid differs)" SubscriptionChanged "$WORK/xr-uid.yaml"

edit $T/xr-pinned.yaml "$WORK/xr-id.yaml" 'd["status"]["subscriptionId"] = "88888888-1111-2222-3333-ffffffffffff"'
must_fail "pinned subscriptionId differs from the Subscription" SubscriptionChanged "$WORK/xr-id.yaml"

envedit env-noloc.yaml 'd["data"].delete("location")'
must_fail "missing location in the environment" EnvironmentInvalid $T/xr.yaml "" "$WORK/env-noloc.yaml"
envedit env-norg.yaml 'd["data"]["resourceGroupName"] = "<RESOURCE_GROUP_NAME>"'
must_fail "resourceGroupName is a placeholder" EnvironmentInvalid $T/xr.yaml "" "$WORK/env-norg.yaml"

envedit env-eastus.yaml 'd["data"]["location"] = "eastus"'
must_fail "location not in allowedLocations" LocationNotAllowed $T/xr.yaml "" "$WORK/env-eastus.yaml"
edit $T/xr.yaml "$WORK/xr-eastus.yaml" "$P[\"location\"] = \"eastus\""
must_fail "spec.parameters.location not in allowedLocations" LocationNotAllowed "$WORK/xr-eastus.yaml"
check "pinned XR keeps its location when allowedLocations later excludes it" $T/xr-pinned.yaml "" '
  abort kinds.inspect unless kinds == %w[Environment]' "$WORK/env-eastus.yaml"

# --- XRD CEL (create-time) and the example --------------------------------------------------
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
validate_rejects "external ingress with networking private" "ingress external requires networking public" "$P[\"ingress\"] = \"external\""
validate_rejects "zoneRedundant without infrastructureSubnetId" "zoneRedundant requires infrastructureSubnetId" "$P[\"zoneRedundant\"] = true"
validate_rejects "minReplicas greater than maxReplicas" "minReplicas can't be greater than maxReplicas" "$P[\"minReplicas\"] = 5; $P[\"maxReplicas\"] = 2"
validate_rejects "the :latest tag" ":latest" "$P[\"image\"] = \"ghcr.io/example/hello-api:latest\""
validate_rejects "an image without a tag" "must have a tag or a digest" "$P[\"image\"] = \"ghcr.io/example/hello-api\""
validate_rejects "an image with a registry port but no tag" "must have a tag or a digest" "$P[\"image\"] = \"registry.example.com:5000/hello-api\""
validate_rejects "an unknown size" "Unsupported value\|enum" "$P[\"size\"] = \"xlarge\""
validate_rejects "an unknown identity" "Unsupported value\|enum" "$P[\"identity\"] = \"user\""
validate_rejects "a name of 33 characters" "33\|should be at most 32\|Too long\|maxLength" "$P[\"name\"] = \"a\" * 33"
validate_rejects "a name of 1 character" "minLength\|should be at least 2\|Too short" "$P[\"name\"] = \"a\""
validate_rejects "an uppercase name" "pattern\|should match" "$P[\"name\"] = \"MyApp\""
validate_rejects "a name with two hyphens in a row" "pattern\|should match" "$P[\"name\"] = \"my--app\""
validate_rejects "a name starting with a digit" "pattern\|should match" "$P[\"name\"] = \"1app\""
validate_rejects "a name ending with a hyphen" "pattern\|should match" "$P[\"name\"] = \"my-app-\""
validate_rejects "an infrastructureSubnetId that is not a subnet" "pattern\|should match" "$P[\"infrastructureSubnetId\"] = \"not-a-subnet\""
validate_rejects "an unknown networking value" "Unsupported value\|enum" "$P[\"networking\"] = \"internal\""
validate_rejects "a tag key outside the allowlist" "Allowed tag keys" "$P[\"tags\"][\"a5n-xr-uid\"] = \"x\""
validate_rejects "an unknown deletionPolicy" "Unsupported value\|enum" 'd["spec"]["deletionPolicy"] = "Retain"'
validate_rejects "targetPort 0" "minimum\|greater than or equal" "$P[\"targetPort\"] = 0"
validate_rejects "maxReplicas 11" "maximum\|less than or equal" "$P[\"maxReplicas\"] = 11"
validate_accepts "a digest-pinned image" "$P[\"image\"] = \"ghcr.io/example/hello-api@sha256:3f1c9a7e5b2d48c6a0e9d1f47b8c2a6e5d0f9b3c71a4e8d2c6b0f5a9e3d71c48\""
validate_accepts "a registry port with a tag" "$P[\"image\"] = \"registry.example.com:5000/hello-api:1.0\""
validate_accepts "deletionPolicy Delete" 'd["spec"]["deletionPolicy"] = "Delete"'
validate_accepts "public with external ingress" "$P[\"networking\"] = \"public\"; $P[\"ingress\"] = \"external\""
validate_accepts "zoneRedundant with infrastructureSubnetId" "$P[\"zoneRedundant\"] = true; $P[\"infrastructureSubnetId\"] = \"$INJECTED\""
validate_accepts "a 32 character name" "$P[\"name\"] = \"a\" * 32"
validate_accepts "a name with single hyphens" "$P[\"name\"] = \"my-app-01\""
crossplane resource validate "$XRD" $T/xr.yaml >/dev/null && echo "PASS fixture validates against the XRD"
crossplane resource validate "$XRD" examples/containerapp/containerapp.yaml >/dev/null && echo "PASS example validates against the XRD"
echo "all containerapp render tests passed"
