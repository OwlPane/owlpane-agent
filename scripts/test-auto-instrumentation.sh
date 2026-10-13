#!/usr/bin/env bash
# Render checks for opt-in auto-instrumentation (values.yaml autoInstrumentation): off by default, renders one
# Instrumentation that targets the node agent when enabled, and refuses settings that could not deliver data.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE=(--set endpoint=https://ingest.example.com --set cluster.name=t)
fail() { echo "FAIL: $*" >&2; exit 1; }

# Off by default: no Instrumentation, nothing for the Operator to act on.
if helm template t . "${BASE[@]}" | grep -q '^kind: Instrumentation$'; then fail "rendered an Instrumentation with autoInstrumentation off"; fi

# On (with the host port): exactly one, sending OTLP/HTTP to the node agent on the pod's node.
out="$(helm template t . -n observability "${BASE[@]}" --set autoInstrumentation.enabled=true --set nodeAgent.otlpHostPort=true --set autoInstrumentation.samplerRatio=0.25)"
doc="$(printf '%s\n' "$out" | awk 'BEGIN{RS="\n---\n"} /\nkind: Instrumentation\n/')"
[ "$(printf '%s\n' "$out" | grep -c '^kind: Instrumentation$')" = 1 ] || fail "expected exactly one Instrumentation"
for want in 'apiVersion: opentelemetry.io/v1alpha1' 'name: owlpane' 'namespace: observability' \
  'endpoint: http://$(OTEL_NODE_IP):4318' 'value: http/protobuf' 'type: parentbased_traceidratio' 'argument: "0.25"'; do
  printf '%s' "$doc" | grep -qF -- "$want" || fail "Instrumentation lacks: $want"
done
# The node agent must actually listen on the node for that endpoint.
printf '%s\n' "$out" | grep -q 'containerPort: 4318, hostPort: 4318' || fail "node agent does not expose 4318 on the host"

# Settings that would silently drop every span are refused at render time.
expect_fail() {
  local why="$1"; shift
  if err="$(helm template t . "${BASE[@]}" "$@" 2>&1)"; then fail "rendered although $why"; fi
  printf '%s' "$err" | grep -q "autoInstrumentation" || fail "error for '$why' does not mention autoInstrumentation: $err"
}
expect_fail "otlpHostPort is off" --set autoInstrumentation.enabled=true
expect_fail "the node agent is off" --set autoInstrumentation.enabled=true --set nodeAgent.enabled=false --set nodeAgent.otlpHostPort=true
expect_fail "samplerRatio is above 1" --set autoInstrumentation.enabled=true --set nodeAgent.otlpHostPort=true --set autoInstrumentation.samplerRatio=1.5
expect_fail "samplerRatio is not a number" --set autoInstrumentation.enabled=true --set nodeAgent.otlpHostPort=true --set-string autoInstrumentation.samplerRatio=all

# helm lint must pass with the feature on.
helm lint . "${BASE[@]}" --set autoInstrumentation.enabled=true --set nodeAgent.otlpHostPort=true >/dev/null || fail "helm lint with autoInstrumentation on"
echo "auto-instrumentation: ok"
