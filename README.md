# Owlpane Kubernetes agent

Helm chart **`owlpane-agent`** (OCI). Install the release as **`owlpane`** in namespace **`owlpane`** — same brand as the Owlpane SaaS and `@owlpane/*` SDKs.

Sends Kubernetes node, pod, container and cluster telemetry to your Owlpane ingest gateway using
OpenTelemetry. Status: **alpha**. Tested on a real (kind) cluster: pods run, kubelet and cluster-state
metrics arrive with `k8s.cluster.name` and your project key.

## Install

```bash
kubectl create namespace owlpane
kubectl -n owlpane create secret generic owlpane-ingest --from-literal=key=owl_ing_YOUR_KEY
helm install owlpane oci://ghcr.io/balaji-singh/owlpane-agent --version 0.3.1 -n owlpane \
  --set endpoint=https://ingest.example.com \
  --set apiEndpoint=https://api.example.com \
  --set cluster.name=production-eu
```

Set **`apiEndpoint`** to your Owlpane API public URL so the chart can send heartbeats and (when `ops.enabled=true`) run the operations runner that applies console-queued changes (scale, restart, and similar).

## What it runs

| Piece | Kind | Does |
|---|---|---|
| cluster collector | Deployment (1) | workload state, HorizontalPodAutoscaler gauges (`k8s.hpa.current_replicas`, `desired_replicas`, `min_replicas`, `max_replicas`), PersistentVolumeClaim capacity and phase, restarts, node conditions, Kubernetes events, and optional Service/Ingress object snapshots for routing in the console |
| node agent | DaemonSet | node, pod, container, and volume metrics from the kubelet (`k8s.volume.capacity`, `k8s.node.filesystem.usage`); host-level CPU, memory, disk, load, network and filesystem metrics from the node OS (`hostmetrics`); cloud region and instance type detection (`resourcedetection`); an OTLP receiver applications can send to; optional container logs |
| ops runner | Deployment (1) | When `apiEndpoint` is set: heartbeat + poll for queued operations (`ops.enabled` adds RBAC for apply) |

## What it is allowed to do

**Telemetry (default):** read-only access to nodes, namespaces, pods, services, endpoints, ingresses, PVCs, PVs, storage classes, config map **metadata** (not data), PDBs, jobs, workloads, autoscalers, events, cert-manager Certificates, and Gateway API Gateways/HTTPRoutes (when enabled in values). **No access to Secret objects, no exec, no log API, no write verbs** on the main collector role.

**Operations (optional):** when `ops.enabled=true`, a separate Role allows patch/scale/delete needed for console-queued operations only. `./scripts/test-rbac.sh` fails the build if telemetry RBAC gains write access or Secret/ConfigMap data reads.

To confine operations to specific namespaces instead of a ClusterRole, list them:

```yaml
ops:
  enabled: true
  scopeNamespaces: ["payments", "web"]
```

The chart then renders a namespaced `Role`/`RoleBinding` per listed namespace and no ops ClusterRole.

## Verify the chart signature

Releases are signed keylessly with cosign; the signature lives in the registry next to the chart:

```bash
cosign verify ghcr.io/balaji-singh/owlpane-agent:0.3.1 \
  --certificate-identity-regexp 'https://github.com/.*/owlpane-agent/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Containers run non-root (except when log collection is enabled, which must read the node's log directory), with a read-only filesystem and all capabilities dropped.

**Host metrics (default on):** `nodeAgent.hostmetrics.enabled=true` mounts the host's root filesystem **read-only** at `/hostfs` so the `hostmetrics` receiver can read `/hostfs/proc` and `/hostfs/sys` for node CPU, memory, disk, load, network and filesystem series. The mount is `HostToContainer` propagation, the container keeps `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false` and dropped capabilities, and no host path is ever written. Set `nodeAgent.hostmetrics.enabled=false` to drop the mount and the receiver. Kubernetes carbon attribution stays on `kubeletstats`; host metrics feed the Infrastructure → Hosts view and validation cross-checks.

**Cloud detection (default on):** `nodeAgent.resourcedetection.enabled=true` adds `cloud.provider`, `cloud.region` and `host.type` to node metrics (detectors: `env`, then GCP, EC2, Azure; 5 s timeout, no override of existing attributes). The `env` detector reads `OTEL_RESOURCE_ATTRIBUTES`, which the chart sets to `host.name=<node name>`; on clusters with no cloud metadata API, set the region and instance type yourself via `nodeAgent.extraEnv` (an example is commented in `values.yaml` — include `host.name=$(K8S_NODE_NAME)` in the value, because your entry replaces the chart's own).

## Privacy defaults

Pod labels and annotations are **not** attached unless you list them, and container logs are **off**
until you enable them (`logs.enabled=true`), because both often contain personal data. The ingest key
lives in a Secret, never in the chart.

Console: **Infrastructure → Databases** (inventory + onboarding wizard), **Kubernetes → Cluster explorer** (inventory and safe ops), and **Settings → Integrations** (Helm generator). See [database onboarding](https://github.com/balaji-singh/owlpane/blob/main/api/docs/ops/database-onboarding.md).

## Database integrations (Postgres, Redis)

Off by default. Enable a small extra collector that reads database health with a read-only account and sends it as
metrics under the service name you choose:

```yaml
integrations:
  enabled: true
  postgres:
    - name: orders-db
      endpoint: orders-db.default.svc:5432
      secret: { name: orders-db-monitor, userKey: username, passwordKey: password }
  redis:
    - name: session-cache
      endpoint: session-cache.default.svc:6379
      secret: { name: session-cache-monitor, passwordKey: password }
```

Create the Secrets yourself (`kubectl create secret generic ...`); the chart never holds a credential. For Postgres run
`GRANT pg_monitor TO owlpane;`; for Redis an ACL user limited to `+info +ping` is enough. The pod has no Kubernetes API
access, a read-only root filesystem and no extra capabilities. `test-rbac.sh` renders this configuration and has the real
collector validate it. Verified against throwaway Postgres 16 and Redis 7 containers: 12 Postgres and 26 Redis metrics arrived under the configured service names. Not yet verified: a Postgres over TLS, or Redis with ACL credentials.

## Network collector

Off by default. When `networkCollector.enabled=true` the chart runs a DaemonSet that reads the node's `/proc/net/tcp` and posts `owlpane.flow.*` logs (`source=conntrack`). It records endpoints and a byte placeholder, not packet payloads. Optional `networkCollector.beyla.enabled=true` adds Grafana Beyla for eBPF network **metrics** (privileged). That container does not decrypt TLS.

Namespace capture filters are not applied by the conntrack loop (it is node-scoped). Port filters are `networkCollector.captureFilters.ports`.

Optional `networkCollector.ebpfCapture.enabled=true` (with `imagePublished=true`) runs a separate privileged DaemonSet using `ghcr.io/balaji-singh/network-ebpf` — **v0.1.0 is a bootstrap** host `/proc` sampler (`owlpane.flow.source=ebpf-capture`), not full CO-RE packet capture.

## Network device monitoring (NDM)

Off by default. When `ndm.enabled=true` the chart runs a single small Deployment that polls your routers,
switches and firewalls over **SNMP v2c/v3** and **ICMP ping**, and reports interface throughput, errors,
discards and oper-status, device CPU/memory, and ping RTT/loss — plus an inventory record (vendor, model,
sysDescr) per device. Credentials live in Secrets you create; the chart never holds a community string:

```bash
kubectl -n owlpane create secret generic ndm-core-switch --from-literal=community='…'
```

```yaml
ndm:
  enabled: true
  devices:
    - name: core-switch
      host: 10.0.0.2
      version: v2c
      communitySecret: { name: ndm-core-switch, key: community }
```

SNMPv3 (`version: v3` with `v3.userSecret`, optional `authKeySecret`/`privKeySecret` for authNoPriv/authPriv)
is supported per device — see `values.yaml`. The pod mounts no service-account token, needs no Kubernetes
RBAC, and adds only `NET_RAW` (for ping) to a dropped-all capability set. `./scripts/test-ndm.sh` runs the
poller against stubbed SNMP/ping and validates the exact OTLP payloads it emits. Devices appear in the
console under **Infrastructure → Network devices** within two poll intervals.

The poller also reads the **LLDP** and **CDP** neighbor tables (`owlpane.ndm.neighbor` logs — local port,
remote device/port/platform) which power the console topology map, and the **ENTITY-SENSOR-MIB** table
(`snmp.sensor.value` / `snmp.sensor.status` with `owlpane.ndm.sensor.{name,type,status}` attributes) for
temperature, fan rpm, voltage, watts and optics DOM (dBm) readings.

### Subnet discovery (opt-in)

`ndm.discovery.enabled=true` adds a second container that ping-sweeps one CIDR (prefix /22 or smaller,
rate-limited via `ratePerSecond`), probes SNMP `sysName` on responders, and reports
`owlpane.ndm.discovered` logs plus one `owlpane.ndm.discovery.run` audit record per sweep (cidr, hosts
scanned, up, snmp-answered, duration). Discovered hosts that are not yet monitored appear in the console
with a one-click path into the add-device wizard. The probing community comes from its own Secret:

```yaml
ndm:
  enabled: true
  discovery:
    enabled: true
    cidr: 10.0.0.0/24
    communitySecret: { name: ndm-discovery, key: community }
```

The poller also reads **BGP** (`snmp.bgp.peer.state` with peer IP + remote AS; a WARN event log when a peer
leaves `established`) and **OSPF** (`snmp.ospf.neighbor.state`) tables for routing-protocol visibility.

### Flow export (NetFlow v5/v9 + IPFIX)

`ndm.flow.enabled=true` runs a small Go receiver (stdlib-only, scratch image) with a UDP Service. Point
device flow export at it (`ip flow-export destination <service-ip> 2055` on Cisco, `sflow`/`ipfix`
equivalents elsewhere); conversations are aggregated in memory and posted as `owlpane.ndm.flow.*` logs
(src/dst IP+port, protocol, bytes, packets, TCP flags) every `intervalSeconds`. Exporter IPs are mapped
to device names from `ndm.devices`. No packet payloads are captured. Use `serviceType: NodePort` (or a
LoadBalancer) when exporters can't route to the pod network.

### Config backup (opt-in)

`ndm.configBackup.enabled=true` adds a container that SSHes to each device with
`configBackup.sshSecret` set, runs `show running-config` (override per device with
`configBackup.command`), **redacts** credentials (passwords, communities, keys — best effort, Cisco/
Juniper/Arista/Fortinet idioms), and posts an `owlpane.ndm.config` log only when the content hash
changes — a versioned config history the console can diff. SSH credentials live in a Secret with
username + password keys; the raw config never leaves the cluster unredacted.

## Footprint

| Profile | Requested on one node |
|---------|------------------------|
| `values-minimal.yaml` | 50m CPU / 128Mi (node agent only) |
| default | 100m CPU / 256Mi (node agent + cluster collector) |
| `ops.enabled=true` | adds 10m / 32Mi for the shell ops runner |
| `ndm.enabled=true` | adds 20m / 64Mi for the SNMP poller (one replica, not per node) |

`./scripts/test-footprint.sh` fails if the default profile grows past that baseline. The ops runner stays a short shell script on purpose: smaller image, fewer CVEs, and the script is auditable.

## Uninstall

`helm uninstall owlpane -n owlpane` removes everything the chart created.
