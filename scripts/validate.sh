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
