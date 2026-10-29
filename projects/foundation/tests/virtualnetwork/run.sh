#!/usr/bin/env bash
# Render tests for the VirtualNetwork composition. Needs the crossplane CLI, ruby and Docker.
# Run from anywhere: projects/foundation/tests/virtualnetwork/run.sh
# Each stage mimics one reconcile: pinned status and observed resources are fed back in.
#
# crossplane render keeps one in-memory store. function-kro reads the XR itself through an
# externalRef, so the XR must also be passed with -e, and that copy replaces the one render
# injects spec.resourceRefs into. build_required() therefore adds the refs of the observed
# resources to the copy. render also does not apply XRD defaults to the input XR, so the
# fixtures spell out every default.
set -euo pipefail

cd "$(dirname "$0")/../.."
T=tests/virtualnetwork
COMP=apis/virtualnetwork/composition.yaml
XRD=apis/virtualnetwork/definition.yaml
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

cat $T/subscriptions.yaml >"$WORK/subs-two.yaml"; echo --- >>"$WORK/subs-two.yaml"; cat $T/subscription-b.yaml >>"$WORK/subs-two.yaml"

# --- reconcile 1: nothing pinned yet -------------------------------------------------------
check "reconcile 1: resolver pins subscription, environment and kro inputs; nothing composed" $T/xr.yaml "" '
  abort kinds.inspect unless kinds.empty?
  abort st.inspect unless st["subscription"] == "sub-a" && st["subscriptionUid"] == "4f0c1d2e-0000-4000-8000-00000000000a" && st["subscriptionId"] == "eeeeeeee-1111-2222-3333-ffffffffffff"
  e = st["environment"]
  abort e.inspect unless e["location"] == "westeurope" && e["resourceGroupName"] == "rg-test-default" && e["ipamPoolId"].end_with?("/ipamPools/pool-test") && e["hubVirtualHubId"].end_with?("/virtualHubs/hub-test")
  abort cond["SubscriptionResolved"].inspect unless cond["SubscriptionResolved"]["status"] == "True"
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "True"
  abort cond["EnvironmentDrift"].inspect unless cond["EnvironmentDrift"]["status"] == "False"'

edit $T/xr.yaml "$WORK/xr-sub-b.yaml" 'd["spec"]["subscription"] = "sub-b"; d["spec"]["parameters"]["size"] = "large"'
check "spec.subscription selects one of two Ready Subscriptions" "$WORK/xr-sub-b.yaml" "" '
  abort st.inspect unless st["subscription"] == "sub-b" && st["subscriptionId"] == "99999999-1111-2222-3333-ffffffffffff"
  abort cond["SubscriptionResolved"]["message"] unless cond["SubscriptionResolved"]["message"].include?("spec.subscription")' "$T/env.yaml" "$WORK/subs-two.yaml"

# --- reconcile 2: pins fed back in ---------------------------------------------------------
check "reconcile 2: VNet and NSG (no dependencies), pins win over the EnvironmentConfig, drift is reported" $T/xr-pinned.yaml "" '
  abort kinds.inspect unless kinds == %w[SecurityGroup VirtualNetwork]
  v = res["vnet"]
  f = v["spec"]["forProvider"]
  abort f.inspect unless f.values_at("location", "resourceGroupName") == %w[northeurope rg-pinned]
  abort f["ipAddressPool"].inspect unless f["ipAddressPool"] == [{ "id" => st["environment"]["ipamPoolId"], "numberOfIpAddresses" => "128" }]
  abort v["spec"]["providerConfigRef"].inspect unless v["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "sub-a" }
  abort v["metadata"]["annotations"].inspect unless v["metadata"]["annotations"]["crossplane.io/external-name"] == "spoke"
  abort f["tags"].inspect unless f["tags"] == { "a5n-namespace" => "team-a", "a5n-owner-xr" => "spoke", "a5n-xr-uid" => "7a1b2c3d-0000-4000-8000-000000000001", "costCenter" => "0000", "owner" => "platform-team@example.com", "environment" => "sandbox" }
  abort cond["EnvironmentDrift"].inspect unless cond["EnvironmentDrift"]["status"] == "True" && cond["EnvironmentDrift"]["reason"] == "EnvironmentChanged"
  abort "ready too early" if cond["Ready"]["status"] == "True"'

# --- reconcile 3: VNet Ready, address space allocated --------------------------------------
check "reconcile 3: subnet, NSG and hub connection follow the VNet; association waits" $T/xr-pinned.yaml observed-vnet.yaml '
  abort kinds.inspect unless kinds == %w[SecurityGroup Subnet VirtualHubConnection VirtualNetwork]
  abort st.inspect unless st["addressSpace"] == ["10.20.0.0/24"] && st["vnetName"] == "spoke" && st["resourceId"].end_with?("/virtualNetworks/spoke")
  s = res["subnet"]["spec"]["forProvider"]
  abort s.inspect unless s["addressPrefixes"] == ["10.20.0.0/24"] && s["virtualNetworkName"] == "spoke" && s["resourceGroupName"] == "rg-pinned" && s["defaultOutboundAccessEnabled"] == false
  rules = res["nsg"]["spec"]["forProvider"]["securityRule"]
  abort rules.inspect unless rules.sort_by { |r| r["priority"] }.map { |r| [r["name"], r["priority"], r["access"], r["direction"], r["destinationPortRange"], r["protocol"]] } == [["dns-from-corp", 100, "Allow", "Inbound", "53", "Udp"], ["https-from-vnet", 101, "Allow", "Inbound", "443", "Tcp"], ["deny-internet-inbound", 4096, "Deny", "Inbound", "*", "*"]]
  abort rules.inspect unless rules.map { |r| r["priority"] }.uniq.size == 3 && rules.last["sourceAddressPrefix"] == "Internet"
  h = res["hubConnection"]["spec"]["forProvider"]
  abort h.inspect unless h["virtualHubId"].end_with?("/virtualHubs/hub-test") && h["remoteVirtualNetworkId"].end_with?("/virtualNetworks/spoke")
  abort res["hubConnection"]["metadata"]["annotations"].inspect unless res["hubConnection"]["metadata"]["annotations"]["crossplane.io/external-name"] == "team-a-spoke-7a1b2c3d"
  abort "ready too early" if cond["Ready"]["status"] == "True"'

# --- reconcile 4: everything Ready ---------------------------------------------------------
check "reconcile 4: association composed, status projected, XR Ready, one ProviderConfig, no lock" $T/xr-pinned.yaml observed-all.yaml '
  abort kinds.inspect unless kinds == %w[SecurityGroup Subnet SubnetNetworkSecurityGroupAssociation VirtualHubConnection VirtualNetwork]
  a = res["nsgAssociation"]["spec"]["forProvider"]
  abort a.inspect unless a["subnetId"].end_with?("/subnets/default") && a["networkSecurityGroupId"].end_with?("/networkSecurityGroups/spoke-nsg")
  abort st.inspect unless st["subnetId"].end_with?("/subnets/default") && st["networkSecurityGroupId"].end_with?("/networkSecurityGroups/spoke-nsg")
  abort res.keys.inspect if res.values.any? { |r| r["spec"]["providerConfigRef"] != { "kind" => "ProviderConfig", "name" => "sub-a" } }
  abort "no ManagementLock allowed" if kinds.include?("ManagementLock")
  abort "Ready=#{cond["Ready"].inspect}" unless cond["Ready"]["status"] == "True"
  abort "a5n tags" unless res.values.select { |r| r["spec"]["forProvider"]["tags"] }.all? { |r| r["spec"]["forProvider"]["tags"]["a5n-xr-uid"] == "7a1b2c3d-0000-4000-8000-000000000001" }'

# --- variants ------------------------------------------------------------------------------
edit $T/xr-pinned.yaml "$WORK/xr-nosubnet.yaml" 'd["spec"]["parameters"]["createSubnet"] = false'
check "createSubnet=false: VNet and hub connection only" "$WORK/xr-nosubnet.yaml" observed-vnet.yaml '
  abort kinds.inspect unless kinds == %w[VirtualHubConnection VirtualNetwork]'

edit $T/xr-pinned.yaml "$WORK/xr-nonsg.yaml" 'd["spec"]["parameters"]["networkSecurityGroup"] = { "enabled" => false }'
check "networkSecurityGroup.enabled=false: subnet without NSG or association" "$WORK/xr-nonsg.yaml" observed-all.yaml '
  abort kinds.inspect unless kinds == %w[Subnet VirtualHubConnection VirtualNetwork]'

edit $T/xr-pinned.yaml "$WORK/xr-nopeer.yaml" 'd["spec"]["parameters"]["peerToHub"] = false; d["status"]["environment"].delete("hubVirtualHubId")'
check "peerToHub=false: no hub connection" "$WORK/xr-nopeer.yaml" observed-all.yaml '
  abort kinds.inspect unless kinds == %w[SecurityGroup Subnet SubnetNetworkSecurityGroupAssociation VirtualNetwork]'

edit $T/xr-pinned.yaml "$WORK/xr-sizes.yaml" 'd["spec"]["parameters"]["size"] = "large"; d["spec"]["parameters"]["name"] = "vnet-custom"'
check "size large maps to 512 addresses and parameters.name is the Azure name" "$WORK/xr-sizes.yaml" "" '
  f = res["vnet"]["spec"]["forProvider"]
  abort f.inspect unless f["ipAddressPool"][0]["numberOfIpAddresses"] == "512"
  abort res["vnet"]["metadata"]["annotations"].inspect unless res["vnet"]["metadata"]["annotations"]["crossplane.io/external-name"] == "vnet-custom"'

edit $T/xr-pinned.yaml "$WORK/xr-notags.yaml" 'd["spec"]["parameters"].delete("tags")'
check "without tags only the platform tags are set" "$WORK/xr-notags.yaml" "" '
  abort res["vnet"]["spec"]["forProvider"]["tags"].keys.sort.inspect unless res["vnet"]["spec"]["forProvider"]["tags"].keys.sort == %w[a5n-namespace a5n-owner-xr a5n-xr-uid]'

# --- hub absent: not fatal, the connection is not composed ---------------------------------
ruby -ryaml -e 'd = YAML.load_file(ARGV[0]); d["data"].delete("hubVirtualHubId"); File.write(ARGV[1], d.to_yaml)' $T/env.yaml "$WORK/env-nohub.yaml"
edit $T/xr-pinned.yaml "$WORK/xr-nohub.yaml" 'd["status"]["environment"].delete("hubVirtualHubId")'
check "hub absent: VNet still composed, no hub connection, EnvironmentValid=False" "$WORK/xr-nohub.yaml" observed-vnet.yaml '
  abort kinds.inspect unless kinds == %w[SecurityGroup Subnet VirtualNetwork]
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "False" && cond["EnvironmentValid"]["reason"] == "HubNotConfigured"' "$WORK/env-nohub.yaml"

ruby -ryaml -e 'd = YAML.load_file(ARGV[0]); d["data"]["hubVirtualHubId"] = "<PLACEHOLDER>"; File.write(ARGV[1], d.to_yaml)' $T/env.yaml "$WORK/env-hub-placeholder.yaml"
check "hub still a placeholder: treated as absent" $T/xr.yaml "" '
  abort cond["EnvironmentValid"]["reason"] unless cond["EnvironmentValid"]["reason"] == "HubNotConfigured"
  abort st["environment"].inspect if st["environment"].key?("hubVirtualHubId")' "$WORK/env-hub-placeholder.yaml"

# --- hub added or removed after pinning: the pinned environment block is re-emitted unchanged -
check "hub added to the environment later: pinned block unchanged, no hub connection, drift reported" "$WORK/xr-nohub.yaml" observed-vnet.yaml '
  abort st["environment"].inspect unless st["environment"] == YAML.load_file("tests/virtualnetwork/xr-pinned.yaml")["status"]["environment"].reject { |k, _| k == "hubVirtualHubId" }
  abort kinds.inspect unless kinds == %w[SecurityGroup Subnet VirtualNetwork]
  abort cond["EnvironmentDrift"].inspect unless cond["EnvironmentDrift"]["status"] == "True" && cond["EnvironmentDrift"]["message"].include?("hub was added")'
check "hub removed from the environment later: pinned block unchanged, hub connection kept" $T/xr-pinned.yaml observed-vnet.yaml '
  abort st["environment"].inspect unless st["environment"] == YAML.load_file("tests/virtualnetwork/xr-pinned.yaml")["status"]["environment"]
  abort kinds.inspect unless kinds.include?("VirtualHubConnection")
  abort cond["EnvironmentDrift"].inspect unless cond["EnvironmentDrift"]["status"] == "True" && cond["EnvironmentDrift"]["message"].include?("hubVirtualHubId") || cond["EnvironmentDrift"]["message"].include?("hub")' "$WORK/env-nohub.yaml"
ruby -ryaml -e 'd = YAML.load_file(ARGV[0]); d["data"].delete("ipamPoolId"); File.write(ARGV[1], d.to_yaml)' $T/env.yaml "$WORK/env-noipam.yaml"
ruby -ryaml -e 'd = YAML.load_file(ARGV[0]); d["data"]["ipamPoolId"] = d["data"]["ipamPoolId"].sub("pool-test", "pool-other"); File.write(ARGV[1], d.to_yaml)' $T/env.yaml "$WORK/env-ipam.yaml"
check "ipamPoolId changed in the environment: pinned pool kept, drift reported" $T/xr-pinned.yaml "" '
  abort st["environment"].inspect unless st["environment"]["ipamPoolId"].end_with?("/ipamPools/pool-test")
  abort cond["EnvironmentDrift"].inspect unless cond["EnvironmentDrift"]["message"].include?("ipamPoolId")' "$WORK/env-ipam.yaml"
check "ipamPoolId removed from the environment later: a pinned virtual network keeps reconciling" $T/xr-pinned.yaml "" '
  abort kinds.inspect unless kinds.include?("VirtualNetwork")' "$WORK/env-noipam.yaml"

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

ruby -ryaml -e 'd = YAML.load_file(ARGV[0]); d["data"].delete("ipamPoolId"); File.write(ARGV[1], d.to_yaml)' $T/env.yaml "$WORK/env-noipam.yaml"
must_fail "missing ipamPoolId" EnvironmentInvalid $T/xr.yaml "" "$WORK/env-noipam.yaml"
ruby -ryaml -e 'd = YAML.load_file(ARGV[0]); d["data"]["ipamPoolId"] = "<PLACEHOLDER>"; File.write(ARGV[1], d.to_yaml)' $T/env.yaml "$WORK/env-ipam-placeholder.yaml"
must_fail "ipamPoolId is a placeholder" EnvironmentInvalid $T/xr.yaml "" "$WORK/env-ipam-placeholder.yaml"

ruby -ryaml -e 'd = YAML.load_file(ARGV[0]); d["data"]["hubVirtualHubId"] = "not-an-id"; File.write(ARGV[1], d.to_yaml)' $T/env.yaml "$WORK/env-hub-bad.yaml"
must_fail "malformed hubVirtualHubId" EnvironmentInvalid $T/xr.yaml "" "$WORK/env-hub-bad.yaml"

ruby -ryaml -e 'd = YAML.load_file(ARGV[0]); d["data"]["location"] = "eastus"; File.write(ARGV[1], d.to_yaml)' $T/env.yaml "$WORK/env-eastus.yaml"
must_fail "location not in allowedLocations" LocationNotAllowed $T/xr.yaml "" "$WORK/env-eastus.yaml"
edit $T/xr.yaml "$WORK/xr-eastus.yaml" 'd["spec"]["parameters"]["location"] = "eastus"'
must_fail "spec.parameters.location not in allowedLocations" LocationNotAllowed "$WORK/xr-eastus.yaml"
check "pinned XR keeps its location when allowedLocations later excludes it" $T/xr-pinned.yaml "" '
  abort kinds.inspect unless kinds == %w[SecurityGroup VirtualNetwork]' "$WORK/env-eastus.yaml"

# --- XRD CEL (create-time) and the example --------------------------------------------------
validate_rejects() { # name pattern ruby-edit
  edit $T/xr.yaml "$WORK/xr-cel.yaml" "$3"
  local out
  out=$(crossplane resource validate "$XRD" "$WORK/xr-cel.yaml" 2>&1 || true)
  if grep -q "$2" <<<"$out"; then echo "PASS XRD rejects $1"; else echo "FAIL XRD accepts $1"; echo "$out" | head -5; exit 1; fi
}
validate_rejects "allowInbound with the NSG disabled" "requires networkSecurityGroup.enabled" 'd["spec"]["parameters"]["networkSecurityGroup"]["enabled"] = false'
validate_rejects "an inbound rule from 0.0.0.0/0" "RFC 1918" 'd["spec"]["parameters"]["networkSecurityGroup"]["allowInbound"][0]["sourceAddressPrefix"] = "0.0.0.0/0"'
validate_rejects "an inbound rule from 0.0.0.0/1 (split internet)" "RFC 1918" 'd["spec"]["parameters"]["networkSecurityGroup"]["allowInbound"][0]["sourceAddressPrefix"] = "0.0.0.0/1"'
validate_rejects "an inbound rule from 128.0.0.0/1 (split internet)" "RFC 1918" 'd["spec"]["parameters"]["networkSecurityGroup"]["allowInbound"][0]["sourceAddressPrefix"] = "128.0.0.0/1"'
validate_rejects "an inbound rule from the public range 1.0.0.0/8" "RFC 1918" 'd["spec"]["parameters"]["networkSecurityGroup"]["allowInbound"][0]["sourceAddressPrefix"] = "1.0.0.0/8"'
validate_rejects "an inbound rule from 999.999.999.999/8" "RFC 1918" 'd["spec"]["parameters"]["networkSecurityGroup"]["allowInbound"][0]["sourceAddressPrefix"] = "999.999.999.999/8"'
validate_rejects "an inbound rule from 10.256.0.0/16 (octet over 255)" "RFC 1918" 'd["spec"]["parameters"]["networkSecurityGroup"]["allowInbound"][0]["sourceAddressPrefix"] = "10.256.0.0/16"'
validate_rejects "an inbound rule from 10.0.0.0/7 (outside 10/8)" "RFC 1918" 'd["spec"]["parameters"]["networkSecurityGroup"]["allowInbound"][0]["sourceAddressPrefix"] = "10.0.0.0/7"'
validate_rejects "an inbound rule from 172.32.0.0/16 (outside 172.16/12)" "RFC 1918" 'd["spec"]["parameters"]["networkSecurityGroup"]["allowInbound"][0]["sourceAddressPrefix"] = "172.32.0.0/16"'
validate_rejects "an inbound rule from 192.168.0.0/15 (outside 192.168/16)" "RFC 1918" 'd["spec"]["parameters"]["networkSecurityGroup"]["allowInbound"][0]["sourceAddressPrefix"] = "192.168.0.0/15"'
validate_rejects "an inbound rule from the Internet tag" "RFC 1918" 'd["spec"]["parameters"]["networkSecurityGroup"]["allowInbound"][0]["sourceAddressPrefix"] = "Internet"'
validate_rejects "an inbound rule from a public source on port 22" "RFC 1918" 'd["spec"]["parameters"]["networkSecurityGroup"]["allowInbound"][0]["sourceAddressPrefix"] = "8.8.8.8/32"; d["spec"]["parameters"]["networkSecurityGroup"]["allowInbound"][0]["port"] = 22'
validate_rejects "a tag key outside the allowlist" "Allowed tag keys" 'd["spec"]["parameters"]["tags"]["a5n-xr-uid"] = "x"'

for p in 10.1.0.0/16 10.255.255.255/32 172.16.0.0/12 172.31.1.0/24 192.168.1.0/24 192.168.0.0/16; do
  edit $T/xr.yaml "$WORK/xr-ok.yaml" "d[\"spec\"][\"parameters\"][\"networkSecurityGroup\"][\"allowInbound\"][0][\"sourceAddressPrefix\"] = \"$p\""
  crossplane resource validate "$XRD" "$WORK/xr-ok.yaml" >/dev/null && echo "PASS XRD accepts source $p"
done
crossplane resource validate "$XRD" $T/xr.yaml >/dev/null && echo "PASS fixture validates against the XRD"
crossplane resource validate "$XRD" examples/virtualnetwork/virtualnetwork.yaml >/dev/null && echo "PASS example validates against the XRD"
echo "all virtualnetwork render tests passed"
