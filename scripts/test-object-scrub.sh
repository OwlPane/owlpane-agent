#!/usr/bin/env bash
# Runs the REAL k8s_objects receiver (collector 0.161.x) against a fake Kubernetes API that serves a ConfigMap and a Pod
# full of secrets, through the cluster collector's rendered transform/strip_object_bodies processor, and fails if any
# secret value still comes out. Also checks what the console needs is kept: ConfigMap keys, env var names,
# configMapKeyRef, tolerations, images. Uses docker (like test-rbac.sh) or, if OTELCOL points at a collector binary, that.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v docker >/dev/null 2>&1 && [[ -z "${OTELCOL:-}" ]]; then echo "SKIP: needs docker or OTELCOL=/path/to/otelcol-contrib"; exit 0; fi
PYTHON=python3
if ! python3 -c "import yaml" 2>/dev/null; then
  VENV="$(pwd)/scripts/.helm-test-venv"
  [[ -x "$VENV/bin/python3" ]] || { python3 -m venv "$VENV"; "$VENV/bin/pip" install -q pyyaml; }
  PYTHON="$VENV/bin/python3"
fi
TMP="$(mktemp -d)"; trap 'kill "${API_PID:-0}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
PORT=18899
helm template t . -n owlpane --set endpoint=https://ingest.example.com --set cluster.name=t > "$TMP/all.yaml"
"$PYTHON" - "$TMP" <<'PY'
import sys, yaml
tmp = sys.argv[1]
docs = [d for d in yaml.safe_load_all(open(f"{tmp}/all.yaml")) if d]
cm = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "owlpane-cluster-collector")
proc = yaml.safe_load(cm["data"]["config.yaml"])["processors"]["transform/strip_object_bodies"]
cfg = {
  "receivers": {"k8s_objects": {"auth_type": "kubeConfig", "objects": [
      {"name": "configmaps", "mode": "pull", "interval": "3s"}, {"name": "pods", "mode": "pull", "interval": "3s"}]}},
  "processors": {"transform/strip_object_bodies": proc},
  "exporters": {"file": {"path": "/out/logs.json"}},
  "service": {"telemetry": {"metrics": {"level": "none"}, "logs": {"level": "error"}},
              "pipelines": {"logs": {"receivers": ["k8s_objects"], "processors": ["transform/strip_object_bodies"], "exporters": ["file"]}}},
}
yaml.safe_dump(cfg, open(f"{tmp}/collector.yaml", "w"), width=100000)
open(f"{tmp}/kubeconfig", "w").write(f"""apiVersion: v1
kind: Config
clusters: [{{name: c, cluster: {{server: "http://127.0.0.1:{sys.argv[2] if len(sys.argv) > 2 else 18899}"}}}}]
contexts: [{{name: x, context: {{cluster: c, user: u}}}}]
current-context: x
users: [{{name: u, user: {{token: t}}}}]
""")
PY
sed -i "s#127.0.0.1:[0-9]*\"#127.0.0.1:${PORT}\"#" "$TMP/kubeconfig"
mkdir -p "$TMP/out"; chmod 777 "$TMP/out"
python3 scripts/test-object-scrub/fake_api.py "$PORT" & API_PID=$!
sleep 1
if [[ -n "${OTELCOL:-}" ]]; then
  sed -i "s#/out/logs.json#$TMP/out/logs.json#" "$TMP/collector.yaml"
  KUBECONFIG="$TMP/kubeconfig" timeout 12 "$OTELCOL" --config "$TMP/collector.yaml" >"$TMP/collector.log" 2>&1 || true
else
  IMG="otel/opentelemetry-collector-contrib:$(grep -E '^appVersion' Chart.yaml | tr -d '" ' | cut -d: -f2)"
  timeout 40 docker run --rm --network host -e KUBECONFIG=/kubeconfig -v "$TMP/kubeconfig:/kubeconfig:ro" -v "$TMP/collector.yaml:/c.yaml:ro" -v "$TMP/out:/out" "$IMG" --config=/c.yaml >"$TMP/collector.log" 2>&1 &
  DPID=$!; sleep 12; docker ps -q --filter ancestor="$IMG" | xargs -r docker stop >/dev/null 2>&1 || true; wait "$DPID" 2>/dev/null || true
fi
python3 - "$TMP/out/logs.json" <<'PY'
import json, sys
def un(v):
    if "kvlistValue" in v: return {x["key"]: un(x["value"]) for x in v["kvlistValue"]["values"]}
    if "arrayValue" in v: return [un(x) for x in v["arrayValue"].get("values", [])]
    for k in ("stringValue", "intValue", "boolValue", "doubleValue"):
        if k in v: return v[k]
bodies = []
for line in open(sys.argv[1]):
    for rl in json.loads(line)["resourceLogs"]:
        for sl in rl["scopeLogs"]:
            bodies += [un(r["body"]) for r in sl["logRecords"]]
assert bodies, "the collector produced no object logs; the test setup is broken"
raw = json.dumps(bodies)
leaked = [s for s in ("hunter2", "abc123", "c2VjcmV0", "sk-live-SECRET123") if s in raw]
assert not leaked, f"secrets still leave the node: {leaked}"
cm = next(b for b in bodies if b.get("kind") == "ConfigMap")
assert set(cm["data"]) == {"DB_PASSWORD", "settings.yaml"} and set(cm["binaryData"]) == {"blob"}, "ConfigMap keys must be kept for the console"
assert cm["metadata"]["annotations"] == {"team": "payments"}, cm["metadata"]["annotations"]
pod = next(b for b in bodies if b.get("kind") == "Pod")
c = pod["spec"]["containers"][0]
env = {e["name"]: e for e in c["env"]}
assert set(env) == {"API_KEY", "MODE", "FROM_CM"} and env["API_KEY"]["value"] == "", env
assert env["FROM_CM"]["valueFrom"]["configMapKeyRef"]["name"] == "app-config", "configMapKeyRef is what links a pod to its ConfigMaps"
assert c["image"] == "nginx:1.27" and pod["spec"]["tolerations"][0]["value"] == "gpu", "images and toleration values must survive"
print("PASS: real k8s_objects output has no ConfigMap values, last-applied annotation or env values; keys, names and refs are kept")
PY
