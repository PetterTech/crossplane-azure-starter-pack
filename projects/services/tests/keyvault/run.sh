#!/usr/bin/env bash
# Render tests for the KeyVault composition. Needs the crossplane CLI, ruby and Docker.
# Run from anywhere: projects/services/tests/keyvault/run.sh
# Each stage mimics one reconcile: pinned status and observed resources are fed back in.
#
# crossplane render keeps one in-memory store. function-kro reads the XR itself through an
# externalRef, so the XR must also be passed with -e, and that copy replaces the one render
# injects spec.resourceRefs into. build_required() therefore adds the refs of the observed
# resources to the copy. render also does not apply XRD defaults to the input XR, so the
# fixtures spell out every default.
set -euo pipefail

cd "$(dirname "$0")/../.."
T=tests/keyvault
COMP=apis/keyvault/composition.yaml
XRD=apis/keyvault/definition.yaml
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

# name_of <rendered file>: the external-name of the Vault
name_of() { ruby -ryaml -e 'puts YAML.load_stream(File.read(ARGV[0])).find { |d| d["kind"] == "Vault" }["metadata"]["annotations"]["crossplane.io/external-name"]' "$1"; }

cat $T/subscriptions.yaml >"$WORK/subs-two.yaml"; echo --- >>"$WORK/subs-two.yaml"; cat $T/subscription-b.yaml >>"$WORK/subs-two.yaml"

PINNED_ID=4f0c1d2e-0000-4000-8000-00000000000a
SUBNET=/subscriptions/cccccccc-1111-2222-3333-dddddddddddd/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-pe
TENANT=11111111-2222-4333-8444-555555555555
PINNED_TENANT=99999999-aaaa-4bbb-8ccc-dddddddddddd

# --- reconcile 1: nothing pinned yet -------------------------------------------------------
check "reconcile 1: resolver pins subscription and environment incl. tenantId and subnetId; nothing composed" $T/xr.yaml "" '
  abort kinds.inspect unless kinds.empty?
  abort st.inspect unless st["subscription"] == "sub-a" && st["subscriptionUid"] == "'$PINNED_ID'" && st["subscriptionId"] == "eeeeeeee-1111-2222-3333-ffffffffffff"
  abort st["environment"].inspect unless st["environment"] == { "location" => "westeurope", "resourceGroupName" => "rg-test-default", "subnetId" => "'$SUBNET'", "tenantId" => "'$TENANT'" }
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
  abort st["environment"].inspect unless st["environment"] == { "location" => "westeurope", "resourceGroupName" => "rg-test-default", "tenantId" => "'$TENANT'" }
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "True"' "$WORK/env-nosubnet.yaml"

# --- reconcile 2: pins fed back in ---------------------------------------------------------
check "reconcile 2: only the vault (the endpoint waits for its ID); hardened; pins win" $T/xr-pinned.yaml "" '
  abort kinds.inspect unless kinds == %w[Vault]
  v = res["vault"]
  f = v["spec"]["forProvider"]
  abort f.inspect unless f.values_at("location", "resourceGroupName", "tenantId") == ["northeurope", "rg-pinned", "'$PINNED_TENANT'"]
  hardened = { "skuName" => "standard", "rbacAuthorizationEnabled" => true, "purgeProtectionEnabled" => true, "softDeleteRetentionDays" => 90,
    "publicNetworkAccessEnabled" => false, "enabledForDeployment" => false, "enabledForDiskEncryption" => false, "enabledForTemplateDeployment" => false }
  abort hardened.reject { |k, v| f[k] == v }.inspect unless hardened.all? { |k, v| f[k] == v }
  abort f["networkAcls"].inspect unless f["networkAcls"] == { "defaultAction" => "Deny", "bypass" => "None", "ipRules" => [] }
  abort "no access policies, no legacy flag" if f.key?("accessPolicy") || f.key?("enableRbacAuthorization")
  abort v["spec"]["providerConfigRef"].inspect unless v["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "sub-a" }
  abort v["spec"]["managementPolicies"].inspect unless v["spec"]["managementPolicies"] == %w[Create Observe Update LateInitialize]
  n = v["metadata"]["annotations"]["crossplane.io/external-name"]
  abort n unless n =~ /\Akv[a-z0-9]{22}\z/
  abort f["tags"].inspect unless f["tags"] == { "a5n-namespace" => "team-a", "a5n-owner-xr" => "secrets", "a5n-xr-uid" => "7a1b2c3d-0000-4000-8000-000000000003", "costCenter" => "0000", "owner" => "platform-team@example.com", "environment" => "sandbox" }
  abort cond["EnvironmentDrift"].inspect unless cond["EnvironmentDrift"]["status"] == "True" && cond["EnvironmentDrift"]["reason"] == "EnvironmentChanged"
  abort cond["EnvironmentDrift"]["message"] unless cond["EnvironmentDrift"]["message"].include?("tenantId")
  abort "ready too early" if cond["Ready"]["status"] == "True"'

# the derived name: deterministic, depends on the Subscription and on the XR name (adoption by name),
# lowercase, starts with a letter, 3-24 characters, never two hyphens in a row
render $T/xr-pinned.yaml >"$WORK/name1.yaml"; render $T/xr-pinned.yaml >"$WORK/name2.yaml"
edit $T/xr-pinned.yaml "$WORK/xr-other-sub.yaml" 'd["spec"]["subscription"] = "sub-b"; d["status"]["subscription"] = "sub-b"; d["status"]["subscriptionUid"] = "4f0c1d2e-0000-4000-8000-00000000000b"; d["status"]["subscriptionId"] = "99999999-1111-2222-3333-ffffffffffff"'
render "$WORK/xr-other-sub.yaml" "" "$T/env.yaml" "$WORK/subs-two.yaml" >"$WORK/name3.yaml"
edit $T/xr-pinned.yaml "$WORK/xr-other-name.yaml" 'd["metadata"]["name"] = "other"'
render "$WORK/xr-other-name.yaml" >"$WORK/name4.yaml"
ruby -ryaml -e '
  n = ARGV.map { |f| YAML.load_stream(File.read(f)).find { |d| d["kind"] == "Vault" }["metadata"]["annotations"]["crossplane.io/external-name"] }
  abort n.inspect unless n[0] == n[1] && n[0] != n[2] && n[0] != n[3] && n[2] != n[3]
  abort n.inspect unless n.all? { |x| x =~ /\A[a-z][a-z0-9]{23}\z/ && x.size == 24 && !x.include?("--") }' "$WORK/name1.yaml" "$WORK/name2.yaml" "$WORK/name3.yaml" "$WORK/name4.yaml" && echo "PASS derived vault name: deterministic, 24 chars lowercase starting with a letter, differs per Subscription and per XR name" \
  || { echo "FAIL derived vault name"; exit 1; }

# a pinned status.vaultName wins over the derived name and over a spec.parameters.name added later
edit $T/xr-pinned.yaml "$WORK/xr-name-pinned.yaml" 'd["status"]["vaultName"] = "kv-pinned-name-01"'
check "pinned status.vaultName wins over the derived name" "$WORK/xr-name-pinned.yaml" "" '
  abort res["vault"]["metadata"]["annotations"].inspect unless res["vault"]["metadata"]["annotations"]["crossplane.io/external-name"] == "kv-pinned-name-01"'
edit "$WORK/xr-name-pinned.yaml" "$WORK/xr-name-both.yaml" 'd["spec"]["parameters"]["name"] = "my-secrets-01"'
check "pinned status.vaultName wins over a spec.parameters.name added later (no second vault)" "$WORK/xr-name-both.yaml" "" '
  abort res["vault"]["metadata"]["annotations"].inspect unless res["vault"]["metadata"]["annotations"]["crossplane.io/external-name"] == "kv-pinned-name-01"'

# deletionPolicy: Orphan leaves no Delete in managementPolicies
edit $T/xr-pinned.yaml "$WORK/xr-delete.yaml" 'd["spec"]["deletionPolicy"] = "Delete"'
check "deletionPolicy Delete: the vault manages everything, the endpoint has no policy override" "$WORK/xr-delete.yaml" observed-vault.yaml '
  abort res["vault"]["spec"]["managementPolicies"].inspect unless res["vault"]["spec"]["managementPolicies"] == ["*"]
  abort res["privateEndpoint"]["spec"].key?("managementPolicies").inspect if res["privateEndpoint"]["spec"].key?("managementPolicies")'

# --- reconcile 3: vault Ready --------------------------------------------------------------
check "reconcile 3: the private endpoint follows the vault; status projected" $T/xr-pinned.yaml observed-vault.yaml '
  abort kinds.inspect unless kinds == %w[PrivateEndpoint Vault]
  abort st.inspect unless st["vaultName"] == "kvfixedname01" && st["resourceId"].end_with?("/vaults/kvfixedname01") && st["vaultUri"] == "https://kvfixedname01.vault.azure.net/"
  abort "no private endpoint id yet" if st.key?("privateEndpointId")
  pe = res["privateEndpoint"]
  p = pe["spec"]["forProvider"]
  abort p.inspect unless p["subnetId"] == st["environment"]["subnetId"] && p["location"] == "northeurope" && p["resourceGroupName"] == "rg-pinned"
  abort p["privateServiceConnection"].inspect unless p["privateServiceConnection"] == { "name" => "keyvault", "isManualConnection" => false, "privateConnectionResourceId" => st["resourceId"], "subresourceNames" => ["vault"] }
  abort p.keys.inspect if p.key?("privateDnsZoneGroup")
  abort pe["spec"]["providerConfigRef"].inspect unless pe["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "sub-a" }
  abort pe["metadata"]["annotations"].inspect unless pe["metadata"]["annotations"]["crossplane.io/external-name"] == "kvfixedname01-pe"
  abort "ready too early" if cond["Ready"]["status"] == "True"'

# --- reconcile 4: everything Ready ---------------------------------------------------------
check "reconcile 4: private endpoint id projected, XR Ready, one ProviderConfig, no lock, no role assignment, no DNS zone group" $T/xr-pinned.yaml observed-all.yaml '
  abort kinds.inspect unless kinds == %w[PrivateEndpoint Vault]
  abort st.inspect unless st["privateEndpointId"].end_with?("/privateEndpoints/kvfixedname01-pe")
  abort "no ManagementLock or RoleAssignment allowed" if kinds.any? { |k| k =~ /Lock|RoleAssignment/ }
  abort docs.map { |d| d["spec"]["providerConfigRef"] }.uniq.inspect unless docs.all? { |d| d["spec"]["providerConfigRef"] == { "kind" => "ProviderConfig", "name" => "sub-a" } }
  abort "Ready=#{cond["Ready"].inspect}" unless cond["Ready"]["status"] == "True"'

# the composed managed resources must validate against the provider CRDs (v2.8.0): objects versus lists
render $T/xr-pinned.yaml observed-all.yaml >"$WORK/out-all.yaml"
render $T/xr-pinned.yaml observed-vault.yaml >"$WORK/out-3.yaml"
render $T/xr-pinned.yaml >"$WORK/out-2.yaml"
edit $T/xr-pinned.yaml "$WORK/xr-public.yaml" 'd["spec"]["parameters"]["networking"] = "public"; d["spec"]["parameters"]["allowedIpRanges"] = ["203.0.113.0/24", "198.51.100.7"]; d["status"]["environment"].delete("subnetId")'
render "$WORK/xr-public.yaml" >"$WORK/out-public.yaml"
for f in out-2 out-3 out-all out-public; do
  ruby -ryaml -e 'puts YAML.load_stream(File.read(ARGV[0])).compact.select { |d| d["apiVersion"] =~ /azure\.m\.upbound\.io/ }.map(&:to_yaml).join' "$WORK/$f.yaml" >"$WORK/$f-mrs.yaml"
  crossplane resource validate $T/crds "$WORK/$f-mrs.yaml" >/dev/null 2>"$WORK/validate.err" || { echo "FAIL $f: managed resources do not validate against the provider CRDs"; cat "$WORK/validate.err"; exit 1; }
done
echo "PASS composed Vault and PrivateEndpoint validate against the provider CRDs"

# --- variants ------------------------------------------------------------------------------
check "public: no private endpoint, public access on, firewall denies all but allowedIpRanges, no bypass" "$WORK/xr-public.yaml" observed-vault.yaml '
  abort kinds.inspect unless kinds == %w[Vault]
  f = res["vault"]["spec"]["forProvider"]
  abort f.inspect unless f["publicNetworkAccessEnabled"] == true && f["networkAcls"] == { "defaultAction" => "Deny", "bypass" => "None", "ipRules" => ["203.0.113.0/24", "198.51.100.7"] }
  abort st.inspect if st.key?("privateEndpointId")
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "True"'

edit "$WORK/xr-public.yaml" "$WORK/xr-public-noips.yaml" 'd["spec"]["parameters"].delete("allowedIpRanges")'
check "public without allowedIpRanges: the firewall allows no one" "$WORK/xr-public-noips.yaml" "" '
  n = res["vault"]["spec"]["forProvider"]["networkAcls"]
  abort n.inspect unless n["ipRules"] == [] && n["defaultAction"] == "Deny"'

edit $T/xr-pinned.yaml "$WORK/xr-flip.yaml" 'd["status"]["environment"].delete("subnetId")'
check "public pinned (no subnetId) flipped to private: no endpoint, EnvironmentValid=False SubnetNotConfigured, vault stays" "$WORK/xr-flip.yaml" observed-vault.yaml '
  abort kinds.inspect unless kinds == %w[Vault]
  abort res["vault"]["spec"]["forProvider"]["publicNetworkAccessEnabled"].inspect unless res["vault"]["spec"]["forProvider"]["publicNetworkAccessEnabled"] == false
  abort cond["EnvironmentValid"].inspect unless cond["EnvironmentValid"]["status"] == "False" && cond["EnvironmentValid"]["reason"] == "SubnetNotConfigured"
  abort st["environment"].inspect if st["environment"].key?("subnetId")' "$T/env.yaml"

edit $T/xr-pinned.yaml "$WORK/xr-explicit.yaml" 'p = d["spec"]["parameters"]; p["name"] = "my-secrets-01"; p["softDeleteDays"] = 30; p.delete("tags")'
check "explicit name, soft delete 30, platform tags only" "$WORK/xr-explicit.yaml" "" '
  v = res["vault"]
  abort v["metadata"]["annotations"].inspect unless v["metadata"]["annotations"]["crossplane.io/external-name"] == "my-secrets-01"
  abort v["spec"]["forProvider"]["softDeleteRetentionDays"].inspect unless v["spec"]["forProvider"]["softDeleteRetentionDays"] == 30
  abort v["spec"]["forProvider"]["tags"].keys.sort.inspect unless v["spec"]["forProvider"]["tags"].keys.sort == %w[a5n-namespace a5n-owner-xr a5n-xr-uid]'

# --- private without a usable subnetId: fail closed ---
envedit env-placeholder.yaml 'd["data"]["subnetId"] = "<SUBNET_ID>"'
envedit env-badsubnet.yaml 'd["data"]["subnetId"] = "not-a-subnet"'
for e in env-nosubnet env-placeholder env-badsubnet; do
  must_fail "private, first reconcile, $e: Fatal SubnetNotConfigured, nothing pinned or composed, Ready not reported" SubnetNotConfigured $T/xr.yaml "" "$WORK/$e.yaml"
  edit $T/xr-pinned.yaml "$WORK/xr-held.yaml" 'd["status"].delete("environment")'
  must_fail "private, no pinned environment ($e): still Fatal on the next reconcile" SubnetNotConfigured "$WORK/xr-held.yaml" "" "$WORK/$e.yaml"
done

check "subnetId removed from the environment later: a pinned vault keeps its endpoint, drift reported" $T/xr-pinned.yaml observed-vault.yaml '
  abort kinds.inspect unless kinds.include?("PrivateEndpoint")
  abort cond["EnvironmentDrift"]["message"].inspect unless cond["EnvironmentDrift"]["message"].include?("subnetId")' "$WORK/env-nosubnet.yaml"

# --- negatives: the resolver fails closed (Fatal): nothing is composed, nothing is deleted --
envedit env-notenant.yaml 'd["data"].delete("tenantId")'
must_fail "missing tenantId in the environment" EnvironmentInvalid $T/xr.yaml "" "$WORK/env-notenant.yaml"
envedit env-tenant-placeholder.yaml 'd["data"]["tenantId"] = "<TENANT_ID>"'
must_fail "tenantId is a placeholder" EnvironmentInvalid $T/xr.yaml "" "$WORK/env-tenant-placeholder.yaml"
envedit env-tenant-bad.yaml 'd["data"]["tenantId"] = "not-a-guid"'
must_fail "tenantId is not a GUID" EnvironmentInvalid $T/xr.yaml "" "$WORK/env-tenant-bad.yaml"
check "pinned XR keeps its tenant when the environment tenantId later disappears, drift reported" $T/xr-pinned.yaml "" '
  abort res["vault"]["spec"]["forProvider"]["tenantId"].inspect unless res["vault"]["spec"]["forProvider"]["tenantId"] == "'$PINNED_TENANT'"' "$WORK/env-notenant.yaml"

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
  abort kinds.inspect unless kinds == %w[Vault]' "$WORK/env-eastus.yaml"

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
validate_rejects "a name of 25 characters" "25\|should be at most 24\|Too long\|maxLength" "$P[\"name\"] = \"a\" * 25"
validate_rejects "a name of 2 characters" "minLength\|should be at least 3\|Too short" "$P[\"name\"] = \"ab\""
validate_rejects "an uppercase name" "pattern\|should match" "$P[\"name\"] = \"MyVault\""
validate_rejects "a name with two hyphens in a row" "pattern\|should match" "$P[\"name\"] = \"my--vault\""
validate_rejects "a name starting with a digit" "pattern\|should match" "$P[\"name\"] = \"1vault\""
validate_rejects "a name ending with a hyphen" "pattern\|should match" "$P[\"name\"] = \"my-vault-\""
validate_rejects "an invalid IP range" "pattern\|should match" "$P[\"networking\"] = \"public\"; $P[\"allowedIpRanges\"] = [\"999.1.1.1\"]"
validate_rejects "an unknown networking value" "Unsupported value\|enum" "$P[\"networking\"] = \"internal\""
validate_rejects "a tag key outside the allowlist" "Allowed tag keys" "$P[\"tags\"][\"a5n-xr-uid\"] = \"x\""
for n in 0 1 8 15; do
  validate_rejects "an allowedIpRanges prefix of /$n" "must be /16 or narrower" "$P[\"networking\"] = \"public\"; $P[\"allowedIpRanges\"] = [\"203.0.113.0/$n\"]"
done
validate_accepts "an allowedIpRanges prefix of /16" "$P[\"networking\"] = \"public\"; $P[\"allowedIpRanges\"] = [\"203.0.0.0/16\"]"
validate_rejects "softDeleteDays 6" "should be greater than or equal to 7\|minimum\|greater than" "$P[\"softDeleteDays\"] = 6"
validate_rejects "softDeleteDays 91" "should be less than or equal to 90\|maximum\|less than" "$P[\"softDeleteDays\"] = 91"
validate_accepts "softDeleteDays 7" "$P[\"softDeleteDays\"] = 7"
validate_rejects "an unknown deletionPolicy" "Unsupported value\|enum" 'd["spec"]["deletionPolicy"] = "Retain"'
validate_accepts "deletionPolicy Delete" 'd["spec"]["deletionPolicy"] = "Delete"'
validate_accepts "public with allowedIpRanges" "$P[\"networking\"] = \"public\"; $P[\"allowedIpRanges\"] = [\"203.0.113.0/24\", \"198.51.100.7\"]"
validate_accepts "a 24 character name" "$P[\"name\"] = \"a\" * 24"
validate_accepts "a name with single hyphens" "$P[\"name\"] = \"my-vault-01\""
crossplane resource validate "$XRD" $T/xr.yaml >/dev/null && echo "PASS fixture validates against the XRD" || { echo "FAIL fixture validates against the XRD"; exit 1; }
crossplane resource validate "$XRD" examples/keyvault/keyvault.yaml >/dev/null && echo "PASS example validates against the XRD" || { echo "FAIL example validates against the XRD"; exit 1; }
echo "all keyvault render tests passed"
