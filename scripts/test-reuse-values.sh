#!/usr/bin/env bash
# `helm upgrade --reuse-values` keeps the previous release's values and does NOT bring in this chart's new defaults: Helm
# replaces the chart's values.yaml with the old release's. A template that reads a key added in this version (say
# .Values.carbon.gpu.enabled) then fails on upgrade, although `helm template` with the new defaults is fine.
# This renders the current templates against the values.yaml of each earlier release, the same way, and fails if any
# combination does not render. Add the new tag to RELEASES after each release.
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASES=(agent-v0.3.1 agent-v0.3.2)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
for tag in "${RELEASES[@]}"; do
  if ! git cat-file -e "$tag:values.yaml" 2>/dev/null; then
    git fetch -q --depth=1 origin "refs/tags/$tag:refs/tags/$tag" || { echo "FAIL: cannot read $tag (fetch tags)"; fail=1; continue; }
  fi
  rm -rf "$TMP/chart"; mkdir -p "$TMP/chart"
  git ls-files -z | xargs -0 -I{} cp --parents {} "$TMP/chart/"
  git show "$tag:values.yaml" > "$TMP/chart/values.yaml"
  for extra in "" "--set carbon.kepler.enabled=true" "--set carbon.gpu.enabled=true" "-f values-carbon.yaml"; do
    # shellcheck disable=SC2086
    if helm template t "$TMP/chart" -n owlpane --set endpoint=https://ingest.example.com --set cluster.name=t $extra >"$TMP/out.yaml" 2>"$TMP/err"; then
      echo "ok   $tag ${extra:-(defaults)}"
    else
      echo "FAIL $tag ${extra:-(defaults)}: $(head -c 400 "$TMP/err")"; fail=1
    fi
  done
done
[[ $fail -eq 0 ]] && echo "PASS: current templates render with every earlier release's values (helm upgrade --reuse-values)"
exit $fail
