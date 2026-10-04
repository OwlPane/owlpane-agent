# Agent upgrades (J4 beta)

## Zero-downtime upgrade

1. Note current chart version: `helm list -n owlpane`
2. `helm upgrade owlpane oci://ghcr.io/owlpane/owlpane-agent --version <chart-version> -n owlpane -f your-values.yaml --reset-values`

### 0.1.3

- Pod labels use `app.kubernetes.io/name: owlpane` and `app.kubernetes.io/part-of: owlpane` (Owlpane SaaS brand). RBAC object names stay `owlpane-agent-<namespace>` so upgrades do not duplicate ClusterRoles.
- Recommended Helm **release name** is `owlpane` (chart package name remains `owlpane-agent` on OCI).
   (Pin the same `--version` you used at install; see `helm list -n owlpane`.)
3. DaemonSet rolls node agents one node at a time; cluster collector Deployment rolls with `maxUnavailable: 0` when configured.
4. Confirm new metrics in **Kubernetes** view within 5 minutes.

## Values to keep stable

- `endpoint` (ingest URL)
- `ingestKey` or secret reference
- `cluster.name`

Changing `cluster.name` creates a new cluster identity in the console.

### Unreleased
- **Security fix:** the cluster collector now removes, on the node and before export, ConfigMap values, the `kubectl.kubernetes.io/last-applied-configuration` annotation and the literal `value` of container env vars in pod specs (`transform/strip_object_bodies`). Earlier versions sent whole objects. Still sent: ConfigMap key names, env var names and `valueFrom` references (the console lists key names and shows which ConfigMaps a pod uses), tolerations, images and the rest of the spec. If you ran an earlier version, ask your Owlpane contact to purge stored object logs for your cluster.
- `scripts/test-object-scrub.sh` runs the real receiver against a fake API server holding secrets and fails if any leaves the node.

### 0.3.1

- Upgrading from chart **&lt; 0.3.0** with `--reuse-values` alone can miss new keys (`nodeAgent.hostmetrics`, `standaloneCollector`, `carbon`). Prefer `helm upgrade … -f values.yaml` (ship defaults from the chart) plus your overrides, or merge your saved values with the current `values.yaml` before upgrade.
- Optional **Kepler** measured node power (`carbon.kepler.enabled`, default **false**): deploys Kepler **v0.12.0** as a privileged host-network DaemonSet and adds a `prometheus/kepler` scrape on the node agent (`kepler_node_cpu_watts` → Owlpane Carbon **measured** mode). Review host `/proc` and `/sys` mounts and privileged caps before enabling in production; see README "Security".
- Optional **GPU metrics** (`carbon.gpu.enabled`, default **false**): adds a `prometheus/gpu` scrape on the node agent for the NVIDIA DCGM exporter you already run (`DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, kept by `metric_relabel_configs`, tagged `service.name=dcgm-exporter` and the node name). Nothing is deployed and no privileges are added. The exporter must be reachable at `<node IP>:carbon.gpu.port` (default 9400); metric names are for dcgm-exporter 3.x and are unverified against your version.

### 0.3.0

- The node agent adds the `hostmetrics` receiver (default on, `nodeAgent.hostmetrics.enabled`): host-level CPU, memory, disk, load, network and filesystem series from the node OS, read from a **read-only** host root mount at `/hostfs`. This is a new `hostPath` mount of `/` — review it against your policies (`test-footprint.sh` covers the footprint); disable with `nodeAgent.hostmetrics.enabled=false` to drop mount and receiver. Kubernetes carbon attribution stays on `kubeletstats`; host metrics feed Infrastructure → Hosts and validation cross-checks.
- The node agent adds a `resourcedetection` processor (default on, `nodeAgent.resourcedetection.enabled`): `cloud.provider`, `cloud.region` and `host.type` on node metrics, detectors `env` → GCP → EC2 → Azure, no override of existing attributes. `host.name` is set to the node name via `OTEL_RESOURCE_ATTRIBUTES`. On clusters with no cloud metadata API, set region and instance type manually through the new `nodeAgent.extraEnv` (example in `values.yaml`).
- No RBAC change: both features read the node, not the API server.

### 0.2.0

- New optional `ndm` component: polls network devices (routers, switches, firewalls) over SNMP v2c/v3 plus ICMP ping and reports `snmp.if.*`, `snmp.cpu.util`, `snmp.memory.used_pct`, `owlpane.ping.*` metrics and `owlpane.ndm.*` inventory logs. Off by default; `ndm.devices` lists targets and credentials come from Secrets you create (`communitySecret` / `v3.userSecret`…), never from values. The pod mounts no service-account token and needs no Kubernetes RBAC. Requires the `ghcr.io/owlpane/owlpane-ndm` image (published on `ndm-v*` tags) or your own build of `docker/ndm`.

### 0.1.10

- Heartbeats only refresh a cluster that is already linked in the console. They no longer create a cluster row. Link the cluster (Connect cluster, or the registry ensure call) before expecting Agent: Live.
- `ops.scopeNamespaces` renders a namespaced Role instead of the cluster-wide ops ClusterRole. Leave it empty to keep the previous behavior.
- The ops runner backs off on HTTP 429 and accepts only a single NetworkPolicy document.

### 0.1.9

- Every `k8s_objects` entry except `events` and `pods` switches from `mode: watch` to `mode: pull` (5-minute interval). This collector build (0.161.0) predates `include_initial_state`, so plain `watch` only emits an object on its *next* change — a Service, PVC, Node, or RBAC object that never changes again after the collector starts would never show up at all. `pull` re-lists everything on that interval instead, so the console's Node/Network/Storage/Workloads tabs are populated from the first sync, not whenever something happens to change. `pods` stays on `watch` (too high-churn/high-cardinality for a full relist) and self-heals within seconds anyway since pods change constantly.

### 0.1.5

- Cluster collector's `k8s_objects` watch (`clusterCollector.objectSnapshots`) adds `nodes`. No new RBAC — `nodes` was already granted for `kubelet_stats` — just a new object kind on an existing permission. Populates node role, taints, labels, addresses, kubelet/kube-proxy/container-runtime versions, capacity vs. allocatable, and cached images on the console's Kubernetes → Nodes pages. A small increase in `k8s_objects` log volume (one row per node, refreshed on change).

### 0.1.4

- `k8s_cluster` receiver enables `k8s.hpa.*`, `k8s.persistentvolumeclaim.*`, and volume metrics the console's Autoscaling and Storage pages query.

## RBAC

Published scope is enforced in CI via `scripts/test-rbac.sh`. Do not grant `secrets` read. `configmaps` read is granted for the cluster explorer; values are stripped on the node (see the unreleased note above).
