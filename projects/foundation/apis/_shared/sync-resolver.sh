#!/usr/bin/env bash
# Inlines _shared/resolver.gotmpl into the resolve-subscription step of the given compositions
# (between the "# BEGIN resolver" and "# END resolver" markers). Packages can't share files, so
# every building-block composition carries an identical copy; scripts/validate.sh checks them.
# usage: projects/foundation/apis/_shared/sync-resolver.sh <composition.yaml>...
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for f in "$@"; do
  ruby -e '
    tmpl, file = ARGV
    body = File.read(tmpl).lines.map { |l| l.strip.empty? ? "\n" : "            #{l}" }.join
    body += "\n" unless body.end_with?("\n")
    text = File.read(file)
    re = /(    # BEGIN resolver[^\n]*\n.*?          template: \|\n).*?(    # END resolver)/m
    abort "#{file}: resolver markers not found" unless text =~ re
    File.write(file, text.sub(re) { "#{$1}#{body}#{$2}" })
  ' "$here/resolver.gotmpl" "$f"
done
