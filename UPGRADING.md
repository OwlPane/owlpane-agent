# Agent upgrades (J4 beta)

## Zero-downtime upgrade

1. Note current chart version: `helm list -n owlpane`
2. `helm upgrade owlpane oci://ghcr.io/balaji-singh/owlpane-agent --version <chart-version> -n owlpane -f your-values.yaml --reset-values`

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

### 0.2.0

- New optional `ndm` component: polls network devices (routers, switches, firewalls) over SNMP v2c/v3 plus ICMP ping and reports `snmp.if.*`, `snmp.cpu.util`, `snmp.memory.used_pct`, `owlpane.ping.*` metrics and `owlpane.ndm.*` inventory logs. Off by default; `ndm.devices` lists targets and credentials come from Secrets you create (`communitySecret` / `v3.userSecret`…), never from values. The pod mounts no service-account token and needs no Kubernetes RBAC. Requires the `ghcr.io/balaji-singh/owlpane-ndm` image (published on `ndm-v*` tags) or your own build of `docker/ndm`.

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

Published scope is enforced in CI via `scripts/test-rbac.sh`. Do not grant `secrets` or `configmaps` read without updating the threat model.
