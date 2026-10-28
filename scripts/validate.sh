#!/usr/bin/env bash
# Local validation for the project skeleton. CI runs the same script.
# Static checks always run. `crossplane project build` runs for foundation and
# services when the crossplane CLI and a Docker daemon are available
# (BUILD=0 skips it, BUILD=1 makes it mandatory).
set -euo pipefail

cd "$(dirname "$0")/.."

ruby -ryaml -rjson -e '
require "find"

errors = []
projects = %w[foundation services landingzone]
semver = /\Av\d+\.\d+\.\d+\z/
range = /\A>=v\d+\.\d+\.\d+ <v\d+\.\d+\.\d+\z/
pins = Hash.new { |h, k| h[k] = {} }

def load_all(path)
  YAML.load_stream(File.read(path)).compact
end

Dir["{projects,setup}/**/*.{yaml,yml}", ".github/**/*.{yaml,yml}"].sort.each do |f|
  begin
    load_all(f)
  rescue StandardError => e
    errors << "#{f}: invalid YAML: #{e.message}"
  end
end

errors << "projects/ must contain exactly #{projects.join(", ")}" unless Dir["projects/*"].map { |d| File.basename(d) }.sort == projects.sort

projects.each do |name|
  f = "projects/#{name}/crossplane-project.yaml"
  unless File.exist?(f)
    errors << "#{f}: missing"
    next
  end
  doc = load_all(f).first
  errors << "#{f}: kind must be dev.crossplane.io/v1alpha1 Project" unless doc["apiVersion"] == "dev.crossplane.io/v1alpha1" && doc["kind"] == "Project"
  errors << "#{f}: metadata.name must be #{name}" unless doc.dig("metadata", "name") == name
  errors << "#{f}: spec.repository must end in /#{name}" unless doc.dig("spec", "repository").to_s.end_with?("/#{name}")
  %w[apis examples tests].each { |d| errors << "projects/#{name}/#{d}/ missing" unless Dir.exist?("projects/#{name}/#{d}") }

  (doc.dig("spec", "dependencies") || []).each do |dep|
    x = dep["xpkg"] or (errors << "#{f}: only xpkg dependencies expected"; next)
    pkg, ver, kind = x["package"], x["version"].to_s, x["kind"]
    if kind == "Configuration"
      errors << "#{f}: #{name} may not depend on #{pkg}" unless name == "landingzone" && pkg =~ %r{/(foundation|services)\z}
      errors << "#{f}: #{pkg} needs a bounded range, got #{ver.inspect}" unless ver =~ range
    else
      errors << "#{f}: #{pkg} must be pinned to an exact version, got #{ver.inspect}" unless ver =~ semver
      pins[pkg]["#{f}"] = ver
    end
  end
  if name == "landingzone"
    got = (doc.dig("spec", "dependencies") || []).select { |d| d.dig("xpkg", "kind") == "Configuration" }.map { |d| d["xpkg"]["package"].split("/").last }.sort
    errors << "#{f}: landingzone must depend on foundation and services, got #{got}" unless got == %w[foundation services]
  end
end

Dir["setup/*.yaml"].sort.each do |f|
  load_all(f).each do |d|
    next unless %w[Function Provider].include?(d["kind"])
    pkg, _, ver = d.dig("spec", "package").rpartition(":")
    errors << "#{f}: #{d["metadata"]["name"]} must be pinned to an exact version" unless ver =~ semver
    pins[pkg][f] = ver
  end
end

pins.each do |pkg, where|
  errors << "version drift for #{pkg}: #{where}" if where.values.uniq.size > 1
end

shared_sa = "provider-azure"
identity_sa = "provider-azure-identity"
drcs = {}
providers = {}
cpcs = []
Dir["setup/*.yaml"].sort.each do |f|
  load_all(f).each do |d|
    case d["kind"]
    when "DeploymentRuntimeConfig"
      drcs[d["metadata"]["name"]] = d
      sa = d.dig("spec", "serviceAccountTemplate", "metadata", "name")
      errors << "#{f}: DRC #{d["metadata"]["name"]} serviceAccountTemplate name must equal the DRC name, got #{sa.inspect}" unless sa == d["metadata"]["name"]
      errors << "#{f}: DRC #{d["metadata"]["name"]} must label pods azure.workload.identity/use: \"true\"" unless d.dig("spec", "deploymentTemplate", "spec", "template", "metadata", "labels", "azure.workload.identity/use") == "true"
      errors << "#{f}: DRC #{d["metadata"]["name"]} must not annotate the ServiceAccount" if d.dig("spec", "serviceAccountTemplate", "metadata", "annotations")
    when "Provider"
      providers[d["metadata"]["name"]] = d
    when "ClusterProviderConfig"
      cpcs << [f, d]
    end
  end
end

errors << "DRCs must be exactly #{[shared_sa, identity_sa].sort}, got #{drcs.keys.sort}" unless drcs.keys.sort == [shared_sa, identity_sa].sort
sas = drcs.values.map { |d| d.dig("spec", "serviceAccountTemplate", "metadata", "name") }
errors << "DRCs must not share a ServiceAccount name: #{sas}" if sas.uniq.size != sas.size

tier = {
  "provider-family-azure" => shared_sa, "provider-azure-storage" => shared_sa, "provider-azure-network" => shared_sa,
  "provider-azure-keyvault" => shared_sa, "provider-azure-containerapp" => shared_sa, "provider-azure-management" => shared_sa,
  "provider-azure-managedidentity" => identity_sa, "provider-azure-authorization" => identity_sa
}
errors << "setup/providers.yaml must contain exactly #{tier.keys.sort}, got #{providers.keys.sort}" unless providers.keys.sort == tier.keys.sort
providers.each do |name, d|
  ref = d.dig("spec", "runtimeConfigRef", "name")
  errors << "Provider #{name} must set an explicit runtimeConfigRef" if ref.nil?
  errors << "Provider #{name} must use runtime config #{tier[name]}, got #{ref.inspect}" if tier.key?(name) && ref != tier[name]
  errors << "Provider #{name} references unknown DRC #{ref.inspect}" if ref && !drcs.key?(ref)
end

wanted_cpcs = { "platform-vending" => "<VENDING_CLIENT_ID>", "platform-identity-admin" => "<IDENTITY_ADMIN_CLIENT_ID>", "platform-runtime" => "<RUNTIME_CLIENT_ID>" }
errors << "setup/clusterproviderconfigs.yaml must define exactly #{wanted_cpcs.keys.sort}, got #{cpcs.map { |_, d| d["metadata"]["name"] }.sort}" unless cpcs.map { |_, d| d["metadata"]["name"] }.sort == wanted_cpcs.keys.sort
cpcs.each do |f, d|
  n = d["metadata"]["name"]
  errors << "#{f}: ClusterProviderConfig must not be named default" if n == "default"
  errors << "#{f}: #{n} apiVersion must be azure.m.upbound.io/v1beta1" unless d["apiVersion"] == "azure.m.upbound.io/v1beta1"
  errors << "#{f}: #{n} credentials.source must be OIDCTokenFile" unless d.dig("spec", "credentials", "source") == "OIDCTokenFile"
  errors << "#{f}: #{n} clientID must be #{wanted_cpcs[n]}" if wanted_cpcs.key?(n) && d.dig("spec", "clientID") != wanted_cpcs[n]
  errors << "#{f}: #{n} tenantID must be <TENANT_ID>" unless d.dig("spec", "tenantID") == "<TENANT_ID>"
  errors << "#{f}: #{n} subscriptionID must be <IDENTITY_SUBSCRIPTION_ID>" unless d.dig("spec", "subscriptionID") == "<IDENTITY_SUBSCRIPTION_ID>"
end
Dir["setup/*.yaml"].each do |f|
  load_all(f).each { |d| errors << "#{f}: namespaced ProviderConfig must not be shipped" if d["kind"] == "ProviderConfig" }
end

guid = /\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/
(Dir["setup/*.{yaml,yml}"] + Dir["docs/*.md"]).sort.each do |f|
  txt = File.read(f)
  errors << "#{f}: contains a real-looking GUID (use <UPPER_SNAKE> placeholders)" if txt =~ guid
  errors << "#{f}: secret material is not allowed" if f.start_with?("setup/") && txt =~ /clientSecret|secretRef|source:\s*Secret|kind:\s*Secret|AZURE_CLIENT_SECRET/
end

kro = pins.select { |k, _| k.end_with?("/function-kro") }
errors << "function-kro must be pinned exactly to v0.3.0: #{kro}" unless !kro.empty? && kro.values.flat_map(&:values).uniq == ["v0.3.0"]
errors << "setup/functions.yaml must install function-go-templating (resolver exception E6)" unless pins.keys.any? { |k| k.end_with?("/function-go-templating") }

errors << "provider versions must be >= v2.7.1" if pins.select { |k, _| k.include?("/upbound/provider-") }.values.flat_map(&:values).any? { |v| Gem::Version.new(v.delete_prefix("v")) < Gem::Version.new("2.7.1") }

begin
  JSON.parse(File.read("renovate.json"))
rescue StandardError => e
  errors << "renovate.json: #{e.message}"
end

Find.find(".") do |p|
  Find.prune if p =~ %r{\A\./(\.git|_output|\.crossplane)\z}
  next unless File.file?(p) && p =~ /\.(ya?ml|json)\z/ && p != "./renovate.json"
  txt = File.read(p)
  errors << "#{p}: platform.example.org must not be used (use platform.a5n.io)" if txt.include?("platform.example.org")
  errors << "#{p}: event-specific value left in" if txt =~ /javazone|pool-nic|rg-nic/i
end

if errors.empty?
  puts "static checks OK (#{pins.size} pinned packages)"
else
  warn errors.map { |e| "FAIL: #{e}" }
  exit 1
end
'

BUILD="${BUILD:-auto}"
if [ "$BUILD" != 0 ]; then
  if command -v crossplane >/dev/null && docker info >/dev/null 2>&1; then
    for p in foundation services; do
      echo "crossplane project build: $p"
      (cd "projects/$p" && crossplane project build)
    done
  elif [ "$BUILD" = 1 ]; then
    echo "FAIL: BUILD=1 but crossplane CLI or Docker is unavailable" >&2
    exit 1
  else
    echo "SKIP: crossplane project build (crossplane CLI or Docker daemon unavailable)"
  fi
fi
echo "validate OK"
