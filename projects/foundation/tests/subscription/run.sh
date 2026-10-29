#!/usr/bin/env bash
# Render tests for the Subscription composition. Needs the crossplane CLI and Docker.
# Run from anywhere: projects/foundation/tests/subscription/run.sh
# Each stage mimics one reconcile: pinned status and observed resources are fed back in.
set -euo pipefail

cd "$(dirname "$0")/../.."
T=tests/subscription
COMP=apis/subscription/composition.yaml
FUNCS=../../setup/functions.yaml
WORK=$T/.work
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

render() { # xr [env] [observed]
  local args=("$T/$1" "$COMP" "$FUNCS" -x)
  [ -n "${2:-}" ] && args+=(-e "$2")
  [ -n "${3:-}" ] && args+=(-o "$T/$3")
  crossplane render "${args[@]}"
}

# check <name> <xr> <observed> <ruby assertions>; the rendered docs are `docs`, the XR is `xr`,
# `st` is its status, `res` maps kind to the composed resource, `kinds` lists composed kinds.
check() {
  local name=$1 xr=$2 observed=$3 code=$4
  render "$xr" "$T/env.yaml" "$observed" >"$WORK/out.yaml"
  if ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV[0])).compact
    xr = docs.shift
    st = xr["status"]
    res = docs.to_h { |d| [d["kind"], d] }
    kinds = docs.map { |d| d["kind"] }.sort
    ready = st["conditions"].find { |c| c["type"] == "Ready" }["status"]
    '"$code"'
  ' "$WORK/out.yaml"; then echo "PASS $name"; else echo "FAIL $name"; exit 1; fi
}

# must_fail <name> <xr> <env file or empty> [observed]
must_fail() {
  local name=$1 out
  if out=$(render "$2" "${3:-}" "${4:-}" 2>&1); then echo "FAIL $name: render succeeded"; exit 1; fi
  if grep -q "fatal" <<<"$out"; then echo "PASS $name"; else echo "FAIL $name: unexpected error"; echo "$out" | head -5; exit 1; fi
}

check "reconcile 1: subscription, identity and usages only; uid and env pinned" xr.yaml "" '
  abort kinds.inspect unless kinds == %w[Subscription Usage Usage UserAssignedIdentity]
  abort "early pins" if st["subscriptionId"] || st["identity"] || st["providerConfigName"]
  abort st.inspect unless st["subscriptionUid"] == "4f0c1d2e-0000-4000-8000-000000000001"
  abort st["environment"].inspect unless st["environment"] == {"location" => "westeurope", "resourceGroupName" => "rg-test-identities"}
  abort "ready too early" if ready == "True"
  sub = docs.find { |d| d["kind"] == "Subscription" }
  abort sub["spec"]["managementPolicies"].inspect if sub["spec"]["managementPolicies"].include?("Delete")'

check "reconcile 2: observed subscription and identity are pinned in status" xr.yaml observed-vended.yaml '
  abort st.inspect unless st["subscriptionId"] == "eeeeeeee-1111-2222-3333-ffffffffffff" && st["identity"]["clientId"] == "11111111-aaaa-bbbb-cccc-222222222222" && st["identity"]["principalId"] && st["identity"]["resourceId"]
  abort kinds.inspect if kinds.include?("ProviderConfig")'

check "reconcile 3: pins win over the EnvironmentConfig, all resources, not Ready without ProviderConfig" xr-pinned.yaml observed-vended.yaml '
  abort kinds.inspect unless kinds == %w[FederatedIdentityCredential ManagementGroupSubscriptionAssociation ProviderConfig RoleAssignment Subscription Usage Usage UserAssignedIdentity]
  abort "pin lost" unless st["environment"] == {"location" => "northeurope", "resourceGroupName" => "rg-pinned-identities"}
  abort "pin lost" unless res["UserAssignedIdentity"]["spec"]["forProvider"].values_at("location", "resourceGroupName") == %w[northeurope rg-pinned-identities]
  abort "ready" if ready == "True"
  ra = res["RoleAssignment"]["spec"]["forProvider"]
  abort ra.inspect unless ra["scope"] == "/subscriptions/eeeeeeee-1111-2222-3333-ffffffffffff" && ra["roleDefinitionId"].end_with?("/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c") && ra["principalType"] == "ServicePrincipal"
  fic = res["FederatedIdentityCredential"]["spec"]["forProvider"]
  abort fic.inspect unless fic["audience"] == ["api://AzureADTokenExchange"] && fic["subject"] == "system:serviceaccount:crossplane-system:provider-azure" && fic["issuer"] == "https://oidc.test.invalid/issuer/"
  pc = res["ProviderConfig"]
  abort pc.inspect unless pc["metadata"]["name"] == "pettertech-sandbox" && pc["metadata"]["namespace"] == "pettertech-sandbox" && pc["spec"]["credentials"]["source"] == "OIDCTokenFile" && pc["spec"]["clientID"] == st["identity"]["clientId"] && pc["spec"]["subscriptionID"] == st["subscriptionId"]
  cpc = ->(k) { res[k]["spec"]["providerConfigRef"]["name"] }
  abort "wrong credentials" unless cpc["Subscription"] == "platform-vending" && cpc["ManagementGroupSubscriptionAssociation"] == "platform-vending" && %w[UserAssignedIdentity FederatedIdentityCredential RoleAssignment].all? { |k| cpc[k] == "platform-identity-admin" }
  abort "no ManagementLock allowed" if kinds.include?("ManagementLock")
  %w[Subscription ManagementGroupSubscriptionAssociation].each { |k| abort "#{k} may be deleted" if res[k]["spec"]["managementPolicies"].include?("Delete") || res[k]["spec"]["managementPolicies"].include?("*") }
  tags = res["Subscription"]["spec"]["forProvider"]["tags"]
  abort tags.inspect unless tags["a5n-xr-uid"] == "4f0c1d2e-0000-4000-8000-000000000001" && tags["a5n-namespace"] == "pettertech-sandbox" && tags["costCenter"] == "0000"'

check "reconcile 4: Ready once the ProviderConfig exists" xr-pinned.yaml observed-ready.yaml '
  abort "not ready" unless ready == "True"
  abort st["providerConfigName"].inspect unless st["providerConfigName"] == "pettertech-sandbox"'

# Negative cases. Keys consumed in reconcile 1 are tested on xr.yaml, the others on the pinned XR.
FRESH_KEYS="billingScopeId location identityResourceGroupName identitySubscriptionId"
LATE_KEYS="tenantId managementGroupId oidcIssuerUrl providerServiceAccountSubject subscriptionRoleDefinitionId"

variant() { # key value|DELETE -> $WORK/env-variant.yaml
  ruby -ryaml -e '
    d = YAML.load_file(ARGV[0])
    ARGV[2] == "DELETE" ? d["data"].delete(ARGV[1]) : d["data"][ARGV[1]] = ARGV[2]
    File.write(ARGV[3], d.to_yaml)' "$T/env.yaml" "$1" "$2" "$WORK/env-variant.yaml"
}

for key in $FRESH_KEYS $LATE_KEYS; do
  if [[ " $FRESH_KEYS " == *" $key "* ]]; then xr=xr.yaml; obs=""; else xr=xr-pinned.yaml; obs=observed-vended.yaml; fi
  variant "$key" DELETE
  must_fail "missing env key $key fails closed" "$xr" "$WORK/env-variant.yaml" "$obs"
  variant "$key" "<${key}_PLACEHOLDER>"
  must_fail "placeholder in $key fails closed" "$xr" "$WORK/env-variant.yaml" "$obs"
done
must_fail "no EnvironmentConfig fails closed" xr.yaml ""
variant providerServiceAccountSubject 'system:serviceaccount:*:*'
must_fail "wildcard subject rejected" xr-pinned.yaml "$WORK/env-variant.yaml" observed-vended.yaml
variant subscriptionRoleDefinitionId 'not-a-guid'
must_fail "malformed role definition rejected" xr-pinned.yaml "$WORK/env-variant.yaml" observed-vended.yaml

# Equality gate: RoleAssignment and ProviderConfig need pinned subscriptionId == observed MR subscriptionId.
sed 's/eeeeeeee-1111/dddddddd-1111/' "$T/observed-vended.yaml" >"$WORK/observed-mismatch.yaml"
check "gate mismatch: pin differs from observed, no RoleAssignment or ProviderConfig, pin unchanged" xr-pinned.yaml .work/observed-mismatch.yaml '
  abort kinds.inspect if kinds.include?("RoleAssignment") || kinds.include?("ProviderConfig")
  abort st.inspect unless st["subscriptionId"] == "eeeeeeee-1111-2222-3333-ffffffffffff"
  abort "ready" if ready == "True"'
check "gate match: pin equals observed, RoleAssignment and ProviderConfig use that ID" xr-pinned.yaml observed-vended.yaml '
  abort kinds.inspect unless kinds.include?("RoleAssignment") && kinds.include?("ProviderConfig")'
check "gate: Subscription not observed yet, nothing is gated on a stale pin" xr-pinned.yaml "" '
  abort kinds.inspect if kinds.include?("RoleAssignment") || kinds.include?("ProviderConfig")'

# Display name <namespace>-<name> is capped at 64 characters (Azure limit): 64 passes, 65 fails closed.
mkname() { ruby -e 'print "n" * ARGV[0].to_i' "$1"; }
for len in 64 65; do
  ns=$(mkname $((len - 1 - 4)))
  sed -e "s/^  namespace: .*/  namespace: $ns/" -e 's/^  name: .*/  name: abcd/' "$T/xr.yaml" >"$WORK/xr-long-$len.yaml"
done
render .work/xr-long-64.yaml "$T/env.yaml" >/dev/null 2>&1 && echo "PASS 64 character display name is accepted" || { echo "FAIL 64 character display name rejected"; exit 1; }
must_fail "65 character display name fails closed" .work/xr-long-65.yaml "$T/env.yaml"

# XRD CEL rules (create-time). One violation per XR. Transition rules (workload immutability,
# status write-once) can't be evaluated by resource validate; see kind-cel.sh.
validate_rejects() { # name pattern ruby-edit
  ruby -ryaml -e 'd = YAML.load_file(ARGV[0]); '"$3"'; File.write(ARGV[1], d.to_yaml)' "$T/xr.yaml" "$WORK/xr-cel.yaml"
  local out
  out=$(crossplane resource validate apis/subscription/definition.yaml "$WORK/xr-cel.yaml" 2>&1 || true)
  if grep -q "$2" <<<"$out"; then echo "PASS XRD rejects $1"; else echo "FAIL XRD accepts $1"; echo "$out" | head -5; exit 1; fi
}
validate_rejects "platform- name prefix" "reserved for the platform team" 'd["metadata"]["name"] = "platform-x"'
validate_rejects "tag key outside the allowlist" "Allowed tag keys" 'd["spec"]["tags"]["a5n-xr-uid"] = "x"'
validate_rejects "more than 10 tags" "Too many: 11" 'd["spec"]["tags"] = (1..11).to_h { |i| ["t#{i}", "x"] }'

# The name "default": the XRD rejects it, and the composition refuses to create a ProviderConfig with it.
sed 's/^  name: pettertech-sandbox$/  name: default/' "$T/xr-pinned.yaml" >"$WORK/xr-default.yaml"
out=$(crossplane resource validate apis/subscription/definition.yaml "$WORK/xr-default.yaml" 2>&1 || true)
if grep -q "reserved" <<<"$out"; then echo "PASS XRD rejects the name default"; else echo "FAIL XRD accepts default"; exit 1; fi
out=$(crossplane render "$WORK/xr-default.yaml" "$COMP" "$FUNCS" -e "$T/env.yaml" -o "$T/observed-vended.yaml" 2>&1 || true)
if grep -q fatal <<<"$out"; then echo "PASS composition refuses a ProviderConfig named default"; else echo "FAIL composition renders a ProviderConfig named default"; exit 1; fi

crossplane resource validate apis/subscription/definition.yaml examples/subscription/subscription.yaml >/dev/null && echo "PASS example validates against the XRD"
echo "all subscription render tests passed"
