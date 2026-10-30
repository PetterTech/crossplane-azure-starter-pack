#!/usr/bin/env ruby
# Writes the OpenAPI v3 documents function-kro needs under `crossplane render --required-schemas`
# (the same shape as `kubectl get --raw /openapi/v3/apis/<group>/<version>`), without a cluster:
# one file per group/version, built from the CRDs in crds/ and from the XRD of the XR.
# usage: schemas.rb <out dir> <xrd.yaml>...  (the XRD of the XR first, then the XRDs of its composed XRs)
require "yaml"
require "json"
require "fileutils"

out, *xrd_paths = ARGV
FileUtils.mkdir_p(out)
here = File.dirname(__FILE__)
docs = Hash.new { |h, k| h[k] = {} }

def reverse_domain(group)
  group.split(".").reverse.join(".")
end

# The API server serves metadata as ObjectMeta; the subset below is what templates use.
OBJECT_META = { "type" => "object", "properties" => {
  "name" => { "type" => "string" }, "generateName" => { "type" => "string" }, "namespace" => { "type" => "string" }, "uid" => { "type" => "string" },
  "annotations" => { "type" => "object", "additionalProperties" => { "type" => "string" } },
  "labels" => { "type" => "object", "additionalProperties" => { "type" => "string" } } } }.freeze

add = lambda do |group, version, kind, schema|
  schema = Marshal.load(Marshal.dump(schema))
  schema["properties"] = (schema["properties"] || {}).merge("metadata" => OBJECT_META)
  schema = schema.merge("x-kubernetes-group-version-kind" => [{ "group" => group, "kind" => kind, "version" => version }])
  docs["#{group}/#{version}"]["#{reverse_domain(group)}.#{version}.#{kind}"] = schema
end

Dir["#{here}/crds/*.yaml"].sort.each do |f|
  crd = YAML.load_file(f)
  g = crd["spec"]["group"]
  k = crd["spec"]["names"]["kind"]
  crd["spec"]["versions"].each { |v| add.call(g, v["name"], k, v["schema"]["openAPIV3Schema"]) }
end

xrd_paths.each do |xrd_path|
  xrd = YAML.load_file(xrd_path)
  xrd["spec"]["versions"].each do |v|
    s = Marshal.load(Marshal.dump(v["schema"]["openAPIV3Schema"]))
    s["properties"]["apiVersion"] = { "type" => "string" }
    s["properties"]["kind"] = { "type" => "string" }
    s["properties"]["status"]["properties"]["conditions"] = { "type" => "array", "items" => { "type" => "object", "x-kubernetes-preserve-unknown-fields" => true } }
    add.call(xrd["spec"]["group"], v["name"], xrd["spec"]["names"]["kind"], s)
  end
end

docs.each do |gv, schemas|
  File.write(File.join(out, "#{gv.tr("/", "_")}.json"),
             JSON.pretty_generate("openapi" => "3.0.0", "info" => { "title" => "Kubernetes CRD Swagger", "version" => "v0.1.0" },
                                  "paths" => {}, "components" => { "schemas" => schemas }))
end
