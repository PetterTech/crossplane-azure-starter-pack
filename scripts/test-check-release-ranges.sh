#!/usr/bin/env bash
# Positive and negative tests for scripts/check-release-ranges.sh. Run: scripts/test-check-release-ranges.sh
set -uo pipefail
cd "$(dirname "$0")/.."

fx=scripts/.test-fixtures
trap 'rm -rf "$fx"' EXIT
rm -rf "$fx"

mkproj() { # name, dependency block ordering: normal|reordered
  mkdir -p "$fx/$1"
  {
    echo "spec:"; echo "  dependencies:"
    echo "    - type: xpkg"; echo "      xpkg:"
    if [ "$2" = normal ]; then
      echo "        apiVersion: pkg.crossplane.io/v1"; echo "        kind: Configuration"
      echo "        package: ghcr.io/x/foundation"; echo '        version: ">=v0.1.0 <v0.2.0"'
    else
      echo '        version: ">=v0.1.0 <v0.2.0"'; echo "        package: ghcr.io/x/foundation"
      echo "        kind: Configuration"; echo "        apiVersion: pkg.crossplane.io/v1"
    fi
  } > "$fx/$1/crossplane-project.yaml"
}
for p in foundation services; do mkdir -p "$fx/$p"; printf 'spec:\n  dependencies: []\n' > "$fx/$p/crossplane-project.yaml"; done
mkproj landingzone normal

failures=0
run() { # expected-exit, description, env..., -- args
  local want=$1 desc=$2; shift 2
  env PROJECTS_DIR="$fx" "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then echo "ok: $desc"; else echo "FAIL: $desc (exit $got, want $want)"; failures=$((failures + 1)); fi
}
S=scripts/check-release-ranges.sh

run 0 "satisfied range"                 PUBLISHED_FOUNDATION="v0.1.0" $S landingzone v0.1.0
run 1 "missing dependency release"      PUBLISHED_FOUNDATION="" $S landingzone v0.1.0
run 1 "dependency outside range"        PUBLISHED_FOUNDATION="v0.2.0" $S landingzone v0.1.0
run 1 "pre-release version"             PUBLISHED_FOUNDATION="v0.1.0" $S landingzone v0.1.0-rc1
run 1 "leading-zero version"            PUBLISHED_FOUNDATION="v0.1.0" $S landingzone v01.0.0
run 1 "leading-zero published ignored"  PUBLISHED_FOUNDATION="v00.1.0" $S landingzone v0.1.0
mkproj landingzone reordered
run 0 "reordered manifest still parsed" PUBLISHED_FOUNDATION="v0.1.0" $S landingzone v0.1.0
run 1 "reordered manifest enforced"     PUBLISHED_FOUNDATION="" $S landingzone v0.1.0

[ $failures = 0 ] && echo "all tests passed"
exit $((failures > 0))
