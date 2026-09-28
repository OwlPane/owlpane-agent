#!/usr/bin/env bash
# Fails if the default install requests more than the published baseline, or if optional
# components render without being enabled. Bump BASELINE_* intentionally when a collector needs more.
set -euo pipefail
cd "$(dirname "$0")/.."
PYTHON=python3
if ! python3 -c "import yaml" 2>/dev/null; then
  VENV="$(pwd)/scripts/.helm-test-venv"
  if [[ ! -x "$VENV/bin/python3" ]]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q pyyaml
  fi
  PYTHON="$VENV/bin/python3"
fi
# Baseline: cluster collector 50m/128Mi + one node-agent 50m/128Mi = 100m / 256Mi requested.
BASELINE_CPU_M=100
BASELINE_MEM_MI=256
OUT="$(mktemp)"
helm template t . -n owlpane --set endpoint=https://ingest.example.com --set cluster.name=t > "$OUT"
"$PYTHON" - "$OUT" "$BASELINE_CPU_M" "$BASELINE_MEM_MI" <<'PY'
import sys, yaml, re
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cpu_m = mem_mi = 0
names = []
def qty_m(v):
    s = str(v)
    if s.endswith("m"): return int(s[:-1])
    return int(float(s) * 1000)
def qty_mi(v):
    s = str(v)
    if s.endswith("Mi"): return int(s[:-2])
    if s.endswith("Gi"): return int(s[:-2]) * 1024
    return int(s) // (1024 * 1024)
for d in docs:
    if d["kind"] not in ("Deployment", "DaemonSet"): continue
    names.append(d["metadata"]["name"])
    # Count one replica of each (DaemonSet is per node; baseline includes one node).
    for c in d["spec"]["template"]["spec"]["containers"]:
        req = (c.get("resources") or {}).get("requests") or {}
        if "cpu" in req: cpu_m += qty_m(req["cpu"])
        if "memory" in req: mem_mi += qty_mi(req["memory"])
banned = ("network-collector", "beyla", "integrations", "log", "ndm")
for n in names:
    for b in banned:
        if b in n and "cluster" not in n:
            raise SystemExit(f"optional component rendered by default: {n}")
if cpu_m > int(sys.argv[2]) or mem_mi > int(sys.argv[3]):
    raise SystemExit(f"default requests {cpu_m}m/{mem_mi}Mi exceed baseline {sys.argv[2]}m/{sys.argv[3]}Mi — bump intentionally")
print(f"PASS: default footprint {cpu_m}m CPU / {mem_mi}Mi memory (baseline {sys.argv[2]}m/{sys.argv[3]}Mi)")
PY