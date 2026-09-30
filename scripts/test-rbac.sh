#!/usr/bin/env bash
# Fails if the agent's ClusterRole ever gains a write verb or access to secrets/exec/logs.
set -euo pipefail
cd "$(dirname "$0")/.."   # the chart is this repository's root (it was deploy/helm/owlpane-agent in the monorepo)
ROOT="$(pwd)"
PYTHON=python3
if ! python3 -c "import yaml" 2>/dev/null; then
  VENV="$ROOT/scripts/.helm-test-venv"
  if [[ ! -x "$VENV/bin/python3" ]]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q pyyaml
  fi
  PYTHON="$VENV/bin/python3"
fi
helm lint . --set endpoint=https://ingest.example.com --set cluster.name=t >/dev/null
# (The owlpane-api and owlpane-ingest charts are linted in their own repositories now.)
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
helm template t . -n owlpane --set endpoint=https://ingest.example.com --set cluster.name=t --set logs.enabled=true --set networkPolicy.enabled=true --set integrations.enabled=true --set 'integrations.redis[0].name=c' --set 'integrations.redis[0].endpoint=c:6379' > "$OUT"
"$PYTHON" - "$OUT" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
roles = [d for d in docs if d["kind"] in ("ClusterRole", "Role")]
assert roles, "no role rendered"
bad = {"secrets", "pods/exec", "pods/log", "pods/attach", "serviceaccounts", "*"}
for r in roles:
    for rule in r["rules"]:
        assert set(rule["verbs"]) <= {"get", "list", "watch"}, f"write verb in {rule}"
        assert not (set(rule["resources"]) & bad), f"forbidden resource in {rule}"
        assert "*" not in rule["apiGroups"], "wildcard api group"
for d in docs:
    if d["kind"] in ("DaemonSet", "Deployment"):
        name = d["metadata"]["name"]
        for c in d["spec"]["template"]["spec"]["containers"]:
            sc = c["securityContext"]
            assert sc["allowPrivilegeEscalation"] is False and sc["readOnlyRootFilesystem"] is True and sc["capabilities"]["drop"] == ["ALL"], f"weak container security in {name}"
        assert "hostNetwork" not in d["spec"]["template"]["spec"], "hostNetwork requested"
print("PASS: read-only RBAC, no secrets access, hardened containers")
PY

# Operations stay off unless explicitly enabled, and even then the extra role is allowlisted.
OPS="$(mktemp)"
helm template t . -n owlpane --set endpoint=https://ingest.example.com --set cluster.name=t --set apiEndpoint=https://api.example.com --set ops.enabled=true > "$OPS"
"$PYTHON" - "$OPS" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
ops = [d for d in docs if d["kind"] == "ClusterRole" and d["metadata"]["name"].endswith("-ops-owlpane")]
assert len(ops) == 1, "ops ClusterRole missing"
allowed = {("apps", "deployments"), ("apps", "statefulsets"), ("apps", "daemonsets"), ("", "pods"), ("", "persistentvolumeclaims"), ("networking.k8s.io", "networkpolicies")}
for rule in ops[0]["rules"]:
    assert "*" not in rule["verbs"]
    assert not ({"secrets", "configmaps", "pods/exec"} & set(rule["resources"]))
    for res in rule["resources"]:
        assert (rule["apiGroups"][0], res) in allowed, (rule["apiGroups"], res)
runner = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "owlpane-ops-runner")
c = runner["spec"]["template"]["spec"]["containers"][0]
sc = c["securityContext"]
assert sc["allowPrivilegeEscalation"] is False and sc["readOnlyRootFilesystem"] is True
script = next(d["data"]["ops.sh"] for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "owlpane-ops-runner")
assert "/v1/kubernetes/agent/ops/claim" in script and "rollout restart" in script
print("PASS: ops runner is opt-in and its role is allowlisted")
PY

SCOPED="$(mktemp)"
helm template t . -n owlpane --set endpoint=https://ingest.example.com --set cluster.name=t --set apiEndpoint=https://api.example.com --set ops.enabled=true --set ops.scopeNamespaces[0]=payments > "$SCOPED"
"$PYTHON" - "$SCOPED" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
assert not any(d["kind"] == "ClusterRole" and "ops" in d["metadata"]["name"] for d in docs), "scoped ops must not render a ClusterRole"
roles = [d for d in docs if d["kind"] == "Role" and d["metadata"]["namespace"] == "payments"]
assert roles, "namespaced ops Role missing"
print("PASS: ops.scopeNamespaces renders a Role, not a ClusterRole")
PY

# NDM: polls devices over SNMP/ICMP — it must need no Kubernetes API access at all.
NDM="$(mktemp)"
helm template t . -n owlpane --set endpoint=https://ingest.example.com --set cluster.name=t --set ndm.enabled=true \
  --set-json 'ndm.devices=[{"name":"sw","host":"10.0.0.2","communitySecret":{"name":"ndm-sw","key":"community"},"configBackup":{"sshSecret":{"name":"ndm-ssh","userKey":"u","passwordKey":"p"}}}]' \
  --set ndm.discovery.enabled=true --set ndm.discovery.cidr=10.0.0.0/24 \
  --set ndm.discovery.communitySecret.name=ndm-disc --set ndm.discovery.communitySecret.key=community \
  --set ndm.configBackup.enabled=true --set ndm.flow.enabled=true > "$NDM"
"$PYTHON" - "$NDM" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
ndm_deps = [d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] in ("owlpane-ndm", "owlpane-ndm-flow")]
assert len(ndm_deps) == 2, "expected owlpane-ndm and owlpane-ndm-flow deployments"
for dep in ndm_deps:
    spec = dep["spec"]["template"]["spec"]
    assert spec.get("automountServiceAccountToken") is False, "ndm pods must not mount a service-account token"
    for c in spec["containers"]:
        sc = c["securityContext"]
        assert sc["runAsNonRoot"] is True and sc["readOnlyRootFilesystem"] is True and sc["allowPrivilegeEscalation"] is False
        assert sc["capabilities"]["drop"] == ["ALL"]
        assert sc["capabilities"].get("add", []) in ([], ["NET_RAW"]), "only ping containers may add NET_RAW"
    assert "hostNetwork" not in spec
    for c in spec["containers"]:
        for e in c.get("env", []):
            if any(s in e["name"] for s in ("COMMUNITY", "SSHPASS", "SSHUSER", "AUTHKEY", "PRIVKEY")):
                assert "valueFrom" in e, f"{e['name']} must come from a Secret"
names = {c["name"] for d in ndm_deps for c in d["spec"]["template"]["spec"]["containers"]}
assert names == {"ndm", "ndm-discovery", "ndm-config", "flow"}, names
# Flow receiver is a UDP Service, no hostNetwork, no capabilities.
svc = next(d for d in docs if d["kind"] == "Service" and d["metadata"]["name"] == "owlpane-ndm-flow")
assert svc["spec"]["ports"][0]["protocol"] == "UDP"
# No ndm-specific RBAC may appear.
assert not any(d["kind"] in ("Role", "ClusterRole") and "ndm" in d["metadata"]["name"] for d in docs), "ndm must not need Kubernetes RBAC"
print("PASS: ndm poller + discovery + config backup + flow receiver are tokenless, secret-backed, and add no RBAC")
PY

# Edge redaction (transform/redact, the count connector that proves it ran) is on by default; a
# regression here would mean personal data and secrets leave the customer's network unredacted.
"$PYTHON" - "$OUT" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "owlpane-node-agent")
cfg = yaml.safe_load(cm["data"]["config.yaml"])
assert "transform/redact" in cfg["processors"], "redaction is on by default but transform/redact is missing"
assert "transform/scrub_urls" in cfg["processors"], "redaction is on by default but transform/scrub_urls is missing"
assert "count" in cfg.get("connectors", {}), "the redaction-counter connector is missing"
for name in ("traces", "logs"):
    pl = cfg["service"]["pipelines"][name]
    assert "transform/redact" in pl["processors"], f"{name} pipeline does not run transform/redact"
    assert "count" in pl["exporters"], f"{name} pipeline does not feed the redaction counter"
assert cfg["service"]["pipelines"]["metrics/redaction"]["receivers"] == ["count"], "no metrics/redaction pipeline reading the counter"
print("PASS: edge redaction (transform/redact + the redaction-counter metric) is on by default")
PY

# Whole Kubernetes objects leave the node through the cluster collector's k8s_objects receiver. ConfigMap values and
# kubectl's last-applied-configuration annotation must be stripped there, in the logs pipeline, before export.
"$PYTHON" - "$OUT" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "owlpane-cluster-collector")
cfg = yaml.safe_load(cm["data"]["config.yaml"])
assert "transform/strip_object_bodies" in cfg["processors"], "the object-body scrubber is missing"
stmts = "\n".join(s for g in cfg["processors"]["transform/strip_object_bodies"]["log_statements"] for s in g["statements"])
for needle in ("last-applied-configuration", 'body["data"]', 'body["binaryData"]', 'body["object"]["data"]', 'body["object"]["binaryData"]'):
    assert needle in stmts, f"scrubber no longer covers {needle}"
procs = cfg["service"]["pipelines"]["logs"]["processors"]
assert "transform/strip_object_bodies" in procs, "the logs pipeline (k8s_objects) does not run the scrubber"
assert procs.index("transform/strip_object_bodies") < procs.index("batch"), "the scrubber must run before batching and export"
print("PASS: ConfigMap values and last-applied-configuration are stripped from object logs before export")
PY

# The collector itself must accept the rendered configuration, so a setting the pinned version does
# not know is caught here and not by a crash-looping pod. Needs docker (skipped when it is absent).
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" "$OUT"' EXIT
  IMG="otel/opentelemetry-collector-contrib:$(grep -E '^appVersion' Chart.yaml | tr -d '" ' | cut -d: -f2)"
  cat > "$TMP/integrations.yaml" <<'YAML'
integrations:
  enabled: true
  postgres:
    - { name: orders-db, endpoint: "orders-db.default.svc:5432", databases: [orders], tls: { insecure: true }, secret: { name: orders-db-monitor } }
  redis:
    - { name: session-cache, endpoint: "session-cache.default.svc:6379", secret: { name: session-cache-monitor } }
    - { name: open-cache, endpoint: "open-cache.default.svc:6379" }
  mysql:
    - { name: billing-db, endpoint: "mysql.default.svc:3306", secret: { name: mysql-monitor } }
  mongodb:
    - { name: events-db, endpoint: "mongo.default.svc:27017", secret: { name: mongo-monitor } }
  kafka:
    - { name: events-bus, brokers: ["kafka.default.svc:9092"] }
  rabbitmq:
    - { name: jobs-queue, endpoint: "http://rabbitmq.default.svc:15672", secret: { name: rabbit-monitor } }
  nginx:
    - { name: edge-proxy, endpoint: "http://nginx.default.svc/status" }
  cloudScrapes:
    - { name: aws-metrics, provider: aws, targets: ["yace.default.svc:5000"] }
YAML
  helm template t . -n owlpane --set endpoint=https://ingest.example.com --set cluster.name=t --set logs.enabled=true --set nodeAgent.kubeletInsecureSkipVerify=true -f "$TMP/integrations.yaml" > "$TMP/all.yaml"
  "$PYTHON" - "$TMP" <<'PY'
import sys, yaml
tmp = sys.argv[1]
for d in yaml.safe_load_all(open(f"{tmp}/all.yaml")):
    if d and d["kind"] == "ConfigMap" and "config.yaml" in d.get("data", {}):
        open(f"{tmp}/{d['metadata']['name']}.yaml", "w").write(d["data"]["config.yaml"])
PY
  # Stand-ins for the files Kubernetes mounts into a pod, so the receivers can start up.
  openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -out "$TMP/ca.crt" -subj /CN=test -days 1 >/dev/null 2>&1
  echo token > "$TMP/token"
  mkdir -p "$TMP/hostfs"   # the node agent's hostmetrics receiver checks that its root_path (/hostfs) exists
  SA=/var/run/secrets/kubernetes.io/serviceaccount
  for f in "$TMP"/owlpane-*.yaml; do
    docker run --rm -e OWLPANE_INGEST_KEY=k -e K8S_NODE_NAME=n -e PG_USER_0=u -e PG_PASSWORD_0=p -e REDIS_PASSWORD_0=p \
      -e MYSQL_USER_0=u -e MYSQL_PASSWORD_0=p -e MONGO_USER_0=u -e MONGO_PASSWORD_0=p -e RABBIT_USER_0=u -e RABBIT_PASSWORD_0=p \
      -e KUBERNETES_SERVICE_HOST=127.0.0.1 -e KUBERNETES_SERVICE_PORT=6443 \
      -v "$TMP/ca.crt:$SA/ca.crt:ro" -v "$TMP/token:$SA/token:ro" -v "$TMP/hostfs:/hostfs:ro" -v "$f:/c.yaml:ro" "$IMG" validate --config=/c.yaml >/dev/null 2>"$TMP/err" || { echo "FAIL: collector rejects $(basename "$f")"; cat "$TMP/err"; exit 1; }
  done
  echo "PASS: the collector accepts every rendered configuration"
fi
