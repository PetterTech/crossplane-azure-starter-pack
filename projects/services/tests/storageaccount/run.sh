#!/usr/bin/env bash
# Render tests for the StorageAccount composition. Needs the crossplane CLI, ruby and Docker.
# Run from anywhere: projects/services/tests/storageaccount/run.sh
# Each stage mimics one reconcile: pinned status and observed resources are fed back in.
#
# crossplane render keeps one in-memory store. function-kro reads the XR itself through an
# externalRef, so the XR must also be passed with -e, and that copy replaces the one render
# injects spec.resourceRefs into. build_required() therefore adds the refs of the observed
# resources to the copy. render also does not apply XRD defaults to the input XR, so the
# fixtures spell out every default.
set -euo pipefail

cd "$(dirname "$0")/../.."
T=tests/storageaccount
COMP=apis/storageaccount/composition.yaml
XRD=apis/storageaccount/definition.yaml
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

cat $T/subscriptions.yaml >"$WORK/subs-two.yaml"; echo --- >>"$WORK/subs-two.yaml"; cat $T/subscription-b.yaml >>"$WORK/subs-two.yaml"

PINNED_ID=4f0c1d2e-0000-4000-8000-00000000000a
SUBNET=/subscriptions/cccccccc-1111-2222-3333-dddddddddddd/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-pe

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

edit $T/xr.yaml "$WORK/xr-public1.yaml" 'd["spec"]["parameters"]["networking"] = "public"'
envedit env-nosubnet.yaml 'd["data"].delete("subnetId")'
check "reconcile 1, public: pinned without a subnetId when the platform has none, EnvironmentValid stays True" "$WORK/xr-public1.yaml" "" '
  abort st["environment"].inspect unless st["environment"] == { "location" => "westeurope", "resourceGroupName" => "rg-test-default" }
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "True"' "$WORK/env-nosubnet.yaml"

# --- reconcile 2: pins fed back in ---------------------------------------------------------
check "reconcile 2: only the account (containers and endpoint wait for its ID); hardened; pins win" $T/xr-pinned.yaml "" '
  abort kinds.inspect unless kinds == %w[Account]
  a = res["account"]
  f = a["spec"]["forProvider"]
  abort f.inspect unless f.values_at("location", "resourceGroupName") == %w[northeurope rg-pinned]
  abort f.inspect unless f.values_at("accountKind", "accountTier", "accountReplicationType") == %w[StorageV2 Standard ZRS]
  hardened = { "httpsTrafficOnlyEnabled" => true, "minTlsVersion" => "TLS1_2", "sharedAccessKeyEnabled" => false, "allowNestedItemsToBePublic" => false,
    "defaultToOauthAuthentication" => true, "crossTenantReplicationEnabled" => false, "isHnsEnabled" => false, "sftpEnabled" => false, "nfsv3Enabled" => false,
    "localUserEnabled" => false, "publicNetworkAccessEnabled" => false }
  abort hardened.reject { |k, v| f[k] == v }.inspect unless hardened.all? { |k, v| f[k] == v }
  abort f["networkRules"].inspect unless f["networkRules"] == { "defaultAction" => "Deny", "bypass" => [], "ipRules" => [] }
  abort f["blobProperties"].inspect unless f["blobProperties"] == { "versioningEnabled" => true, "deleteRetentionPolicy" => [{ "days" => 7 }], "containerDeleteRetentionPolicy" => [{ "days" => 7 }] }
  abort a["spec"]["providerConfigRef"].inspect unless a["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "sub-a" }
  n = a["metadata"]["annotations"]["crossplane.io/external-name"]
  abort n unless n =~ /\A[a-z0-9]{3,24}\z/ && n.size == 24 && n.start_with?("st")
  abort f["tags"].inspect unless f["tags"] == { "a5n-namespace" => "team-a", "a5n-owner-xr" => "data", "a5n-xr-uid" => "7a1b2c3d-0000-4000-8000-000000000002", "costCenter" => "0000", "owner" => "platform-team@example.com", "environment" => "sandbox" }
  abort cond["EnvironmentDrift"].inspect unless cond["EnvironmentDrift"]["status"] == "True" && cond["EnvironmentDrift"]["reason"] == "EnvironmentChanged"
  abort "ready too early" if cond["Ready"]["status"] == "True"'

# the derived name is deterministic and depends on the Subscription
render $T/xr-pinned.yaml >"$WORK/name1.yaml"; render $T/xr-pinned.yaml >"$WORK/name2.yaml"
edit $T/xr-pinned.yaml "$WORK/xr-other-sub.yaml" 'd["spec"]["subscription"] = "sub-b"; d["status"]["subscription"] = "sub-b"; d["status"]["subscriptionUid"] = "4f0c1d2e-0000-4000-8000-00000000000b"; d["status"]["subscriptionId"] = "99999999-1111-2222-3333-ffffffffffff"'
render "$WORK/xr-other-sub.yaml" "" "$T/env.yaml" "$WORK/subs-two.yaml" >"$WORK/name3.yaml"
ruby -ryaml -e '
  n = ARGV.map { |f| YAML.load_stream(File.read(f)).find { |d| d["kind"] == "Account" }["metadata"]["annotations"]["crossplane.io/external-name"] }
  abort n.inspect unless n[0] == n[1] && n[0] != n[2] && n.all? { |x| x =~ /\Ast[a-z0-9]{22}\z/ }' "$WORK/name1.yaml" "$WORK/name2.yaml" "$WORK/name3.yaml" && echo "PASS derived account name: deterministic, 24 chars lowercase alphanumeric, differs per Subscription"

# --- reconcile 3: account Ready ------------------------------------------------------------
check "reconcile 3: containers and private endpoint follow the account; status projected" $T/xr-pinned.yaml observed-account.yaml '
  abort kinds.inspect unless kinds == %w[Account Container Container PrivateEndpoint]
  abort st.inspect unless st["accountName"] == "stfixedname01" && st["resourceId"].end_with?("/storageAccounts/stfixedname01") && st["endpoints"] == { "blob" => "https://stfixedname01.blob.core.windows.net/", "file" => "https://stfixedname01.file.core.windows.net/" }
  abort "no private endpoint id yet" if st.key?("privateEndpointId")
  cs = docs.select { |d| d["kind"] == "Container" }.sort_by { |d| d["metadata"]["annotations"]["crossplane.io/external-name"] }
  abort cs.map { |c| c["metadata"]["annotations"] }.inspect unless cs.map { |c| c["metadata"]["annotations"]["crossplane.io/external-name"] } == %w[curated raw]
  cs.each do |c|
    abort c.inspect unless c["spec"]["forProvider"] == { "storageAccountId" => st["resourceId"], "containerAccessType" => "private" } && c["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "sub-a" }
    abort c["metadata"]["name"] unless c["metadata"]["name"] =~ /\Adata-(raw|curated)-[a-z0-9]{6}\z/
  end
  pe = res["privateEndpoint"]
  p = pe["spec"]["forProvider"]
  abort p.inspect unless p["subnetId"] == st["environment"]["subnetId"] && p["location"] == "northeurope" && p["resourceGroupName"] == "rg-pinned"
  abort p["privateServiceConnection"].inspect unless p["privateServiceConnection"] == { "name" => "storage", "isManualConnection" => false, "privateConnectionResourceId" => st["resourceId"], "subresourceNames" => ["blob"] }
  abort p.keys.inspect if p.key?("privateDnsZoneGroup")
  abort pe["spec"]["providerConfigRef"].inspect unless pe["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "sub-a" }
  abort pe["metadata"]["annotations"].inspect unless pe["metadata"]["annotations"]["crossplane.io/external-name"] == "stfixedname01-pe"
  abort "ready too early" if cond["Ready"]["status"] == "True"'

# --- reconcile 4: everything Ready ---------------------------------------------------------
check "reconcile 4: private endpoint id projected, XR Ready, one ProviderConfig, no lock, no DNS zone group" $T/xr-pinned.yaml observed-all.yaml '
  abort kinds.inspect unless kinds == %w[Account Container Container PrivateEndpoint]
  abort st.inspect unless st["privateEndpointId"].end_with?("/privateEndpoints/stfixedname01-pe")
  abort "no ManagementLock allowed" if kinds.include?("ManagementLock")
  abort docs.map { |d| d["spec"]["providerConfigRef"] }.uniq.inspect unless docs.all? { |d| d["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "sub-a" } }
  abort "Ready=#{cond["Ready"].inspect}" unless cond["Ready"]["status"] == "True"'

# --- variants ------------------------------------------------------------------------------
edit $T/xr-pinned.yaml "$WORK/xr-public.yaml" 'd["spec"]["parameters"]["networking"] = "public"; d["spec"]["parameters"]["allowedIpRanges"] = ["203.0.113.0/24", "198.51.100.7"]; d["status"]["environment"].delete("subnetId")'
check "public: no private endpoint, public access on, firewall denies all but allowedIpRanges, no bypass" "$WORK/xr-public.yaml" observed-account.yaml '
  abort kinds.inspect unless kinds == %w[Account Container Container]
  f = res["account"]["spec"]["forProvider"]
  abort f.inspect unless f["publicNetworkAccessEnabled"] == true && f["networkRules"] == { "defaultAction" => "Deny", "bypass" => [], "ipRules" => ["203.0.113.0/24", "198.51.100.7"] }
  abort st.inspect if st.key?("privateEndpointId")
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "True"'

edit "$WORK/xr-public.yaml" "$WORK/xr-public-noips.yaml" 'd["spec"]["parameters"].delete("allowedIpRanges")'
check "public without allowedIpRanges: the firewall allows no one" "$WORK/xr-public-noips.yaml" "" '
  abort res["account"]["spec"]["forProvider"]["networkRules"].inspect unless res["account"]["spec"]["forProvider"]["networkRules"]["ipRules"] == [] && res["account"]["spec"]["forProvider"]["networkRules"]["defaultAction"] == "Deny"'

edit $T/xr-pinned.yaml "$WORK/xr-flip.yaml" 'd["status"]["environment"].delete("subnetId")'
check "public pinned (no subnetId) flipped to private: no endpoint, EnvironmentValid=False SubnetNotConfigured, account stays" "$WORK/xr-flip.yaml" observed-account.yaml '
  abort kinds.inspect unless kinds == %w[Account Container Container]
  abort res["account"]["spec"]["forProvider"]["publicNetworkAccessEnabled"].inspect unless res["account"]["spec"]["forProvider"]["publicNetworkAccessEnabled"] == false
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "False" && cond["EnvironmentValid"]["reason"] == "SubnetNotConfigured"
  abort st["environment"].inspect if st["environment"].key?("subnetId")' "$T/env.yaml"

edit $T/xr-pinned.yaml "$WORK/xr-explicit.yaml" 'p = d["spec"]["parameters"]; p["name"] = "mydataaccount01"; p["softDeleteDays"] = 0; p["versioning"] = false; p["accountTier"] = "Premium"; p["accountKind"] = "BlockBlobStorage"; p["replication"] = "LRS"; p.delete("tags")'
check "explicit name, soft delete 0, no versioning, Premium BlockBlobStorage LRS, platform tags only" "$WORK/xr-explicit.yaml" "" '
  a = res["account"]
  f = a["spec"]["forProvider"]
  abort a["metadata"]["annotations"].inspect unless a["metadata"]["annotations"]["crossplane.io/external-name"] == "mydataaccount01"
  abort f.inspect unless f.values_at("accountKind", "accountTier", "accountReplicationType") == %w[BlockBlobStorage Premium LRS]
  abort f["blobProperties"].inspect unless f["blobProperties"] == { "versioningEnabled" => false, "deleteRetentionPolicy" => [], "containerDeleteRetentionPolicy" => [] }
  abort f["tags"].keys.sort.inspect unless f["tags"].keys.sort == %w[a5n-namespace a5n-owner-xr a5n-xr-uid]'

edit $T/xr-pinned.yaml "$WORK/xr-file.yaml" 'p = d["spec"]["parameters"]; p["accountTier"] = "Premium"; p["accountKind"] = "FileStorage"; p["replication"] = "ZRS"; p.delete("containers")'
check "FileStorage: no containers, no blobProperties, the endpoint targets the file service" "$WORK/xr-file.yaml" observed-account.yaml '
  abort kinds.inspect unless kinds == %w[Account PrivateEndpoint]
  abort res["account"]["spec"]["forProvider"]["blobProperties"].inspect unless res["account"]["spec"]["forProvider"]["blobProperties"] == {}
  abort res["privateEndpoint"]["spec"]["forProvider"]["privateServiceConnection"]["subresourceNames"].inspect unless res["privateEndpoint"]["spec"]["forProvider"]["privateServiceConnection"]["subresourceNames"] == ["file"]'

edit $T/xr-pinned.yaml "$WORK/xr-nocontainers.yaml" 'd["spec"]["parameters"].delete("containers")'
check "no containers: account and endpoint only" "$WORK/xr-nocontainers.yaml" observed-account.yaml '
  abort kinds.inspect unless kinds == %w[Account PrivateEndpoint]'

# --- private without a usable subnetId: nothing is created --------------------------------
envedit env-placeholder.yaml 'd["data"]["subnetId"] = "<SUBNET_ID>"'
envedit env-badsubnet.yaml 'd["data"]["subnetId"] = "not-a-subnet"'
for e in env-nosubnet env-placeholder env-badsubnet; do
  check "private, first reconcile, $e: nothing pinned or composed, EnvironmentValid=False SubnetNotConfigured" $T/xr.yaml "" '
    abort kinds.inspect unless kinds.empty?
    abort st.inspect if st.key?("environment")
    abort st.inspect unless st["subscription"] == "sub-a"
    abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "False" && cond["EnvironmentValid"]["reason"] == "SubnetNotConfigured"' "$WORK/$e.yaml"
  edit $T/xr-pinned.yaml "$WORK/xr-held.yaml" 'd["status"].delete("environment")'
  check "private, held ($e): still nothing composed on the next reconcile" "$WORK/xr-held.yaml" "" '
    abort kinds.inspect unless kinds.empty?
    abort st.inspect if st.key?("environment")' "$WORK/$e.yaml"
done

check "subnetId removed from the environment later: a pinned account keeps its endpoint, drift reported" $T/xr-pinned.yaml observed-account.yaml '
  abort kinds.inspect unless kinds.include?("PrivateEndpoint")
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
edit $T/xr.yaml "$WORK/xr-eastus.yaml" 'd["spec"]["parameters"]["location"] = "eastus"'
must_fail "spec.parameters.location not in allowedLocations" LocationNotAllowed "$WORK/xr-eastus.yaml"
check "pinned XR keeps its location when allowedLocations later excludes it" $T/xr-pinned.yaml "" '
  abort kinds.inspect unless kinds == %w[Account]' "$WORK/env-eastus.yaml"

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
P='d["spec"]["parameters"]'
validate_rejects "allowedIpRanges with networking private" "allowedIpRanges requires networking public" "$P[\"allowedIpRanges\"] = [\"203.0.113.0/24\"]"
validate_rejects "Premium with StorageV2" "requires accountKind BlockBlobStorage or FileStorage" "$P[\"accountTier\"] = \"Premium\""
validate_rejects "BlockBlobStorage with Standard" "require accountTier Premium" "$P[\"accountKind\"] = \"BlockBlobStorage\""
validate_rejects "FileStorage with Standard" "require accountTier Premium" "$P[\"accountKind\"] = \"FileStorage\""
validate_rejects "Premium with GRS" "supports only replication LRS or ZRS" "$P[\"accountTier\"] = \"Premium\"; $P[\"accountKind\"] = \"BlockBlobStorage\"; $P[\"replication\"] = \"GRS\""
validate_rejects "containers on FileStorage" "FileStorage has no blob service" "$P[\"accountTier\"] = \"Premium\"; $P[\"accountKind\"] = \"FileStorage\""
validate_rejects "a name of 25 characters" "25\|should be at most 24\|Too long\|maxLength" "$P[\"name\"] = \"a\" * 25"
validate_rejects "a name of 2 characters" "minLength\|should be at least 3\|Too short" "$P[\"name\"] = \"ab\""
validate_rejects "an uppercase name" "pattern\|should match" "$P[\"name\"] = \"MyAccount\""
validate_rejects "a name with a hyphen" "pattern\|should match" "$P[\"name\"] = \"my-account\""
validate_rejects "an invalid IP range" "pattern\|should match" "$P[\"networking\"] = \"public\"; $P[\"allowedIpRanges\"] = [\"999.1.1.1\"]"
validate_rejects "more than 10 IP ranges" "maxItems\|should have at most\|Too many" "$P[\"networking\"] = \"public\"; $P[\"allowedIpRanges\"] = (1..11).map { |i| \"203.0.113.#{i}\" }"
validate_rejects "an unknown networking value" "Unsupported value\|enum" "$P[\"networking\"] = \"internal\""
validate_rejects "a tag key outside the allowlist" "Allowed tag keys" "$P[\"tags\"][\"a5n-xr-uid\"] = \"x\""
validate_accepts "public with allowedIpRanges" "$P[\"networking\"] = \"public\"; $P[\"allowedIpRanges\"] = [\"203.0.113.0/24\", \"198.51.100.7\"]"
validate_accepts "Premium BlockBlobStorage LRS" "$P[\"accountTier\"] = \"Premium\"; $P[\"accountKind\"] = \"BlockBlobStorage\"; $P[\"replication\"] = \"LRS\""
validate_accepts "a 24 character name" "$P[\"name\"] = \"a\" * 24"
crossplane resource validate "$XRD" $T/xr.yaml >/dev/null && echo "PASS fixture validates against the XRD"
crossplane resource validate "$XRD" examples/storageaccount/storageaccount.yaml >/dev/null && echo "PASS example validates against the XRD"
echo "all storageaccount render tests passed"
