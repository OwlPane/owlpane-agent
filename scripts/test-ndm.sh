#!/usr/bin/env bash
# Functional smoke test for the ndm poller script: stubs snmpwalk/snmpget/ping/curl on PATH,
# runs two poll cycles, and validates the emitted OTLP JSON.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(mktemp -d)"
OUT="$(mktemp -d)"
if [ "${NDM_TEST_KEEP:-}" = "1" ]; then
  echo "BIN=$BIN OUT=$OUT"
else
  trap 'rm -rf "$BIN" "$OUT"' EXIT
fi

cat > "$BIN/snmpwalk" <<'EOF'
#!/bin/sh
# Canned -Onq output keyed by the final OID arg; counters grow by a file-backed step.
oid=$(eval "printf '%s' \"\${$#}\"")
state="/tmp/ndm-stub-count"
n=1; [ -f "$state" ] && n=$(( $(cat "$state") + 1 )); echo "$n" > "$state"
in=$((1000000 * n)); out=$((2000000 * n))
case "$oid" in
  1.3.6.1.2.1.31.1.1.1.1)  printf '.1.3.6.1.2.1.31.1.1.1.1.1 eth0\n.1.3.6.1.2.1.31.1.1.1.1.2 eth1\n' ;;
  1.3.6.1.2.1.31.1.1.1.15) printf '.1.3.6.1.2.1.31.1.1.1.15.1 1000\n.1.3.6.1.2.1.31.1.1.1.15.2 100\n' ;;
  1.3.6.1.2.1.2.2.1.8)     printf '.1.3.6.1.2.1.2.2.1.8.1 1\n.1.3.6.1.2.1.2.2.1.8.2 2\n' ;;
  1.3.6.1.2.1.31.1.1.1.6)  printf '.1.3.6.1.2.1.31.1.1.1.6.1 %s\n.1.3.6.1.2.1.31.1.1.1.6.2 %s\n' "$in" "$in" ;;
  1.3.6.1.2.1.31.1.1.1.10) printf '.1.3.6.1.2.1.31.1.1.1.10.1 %s\n.1.3.6.1.2.1.31.1.1.1.10.2 %s\n' "$out" "$out" ;;
  1.3.6.1.2.1.2.2.1.14)    printf '.1.3.6.1.2.1.2.2.1.14.1 %s\n' "$n" ;;
  1.3.6.1.2.1.2.2.1.20)    printf '.1.3.6.1.2.1.2.2.1.20.1 0\n' ;;
  1.3.6.1.2.1.2.2.1.13)    printf '.1.3.6.1.2.1.2.2.1.13.1 0\n' ;;
  1.3.6.1.2.1.2.2.1.19)    printf '.1.3.6.1.2.1.2.2.1.19.1 0\n' ;;
  1.3.6.1.2.1.25.3.3.1.2)  printf '.1.3.6.1.2.1.25.3.3.1.2.1 25\n.1.3.6.1.2.1.25.3.3.1.2.2 35\n' ;;
  1.0.8802.1.1.2.1.4.1.1.9)  printf '.1.0.8802.1.1.2.1.4.1.1.9.123.1.1 edge-router\n' ;;
  1.0.8802.1.1.2.1.4.1.1.7)  printf '.1.0.8802.1.1.2.1.4.1.1.7.123.1.1 Gi0/1\n' ;;
  1.0.8802.1.1.2.1.4.1.1.10) printf '.1.0.8802.1.1.2.1.4.1.1.10.123.1.1 "GigabitEthernet0/1"\n' ;;
  1.0.8802.1.1.2.1.3.7.1.3)  printf '.1.0.8802.1.1.2.1.3.7.1.3.1 Gi0/0\n' ;;
  1.3.6.1.4.1.9.9.23.1.2.1.1.6) printf '.1.3.6.1.4.1.9.9.23.1.2.1.1.6.2.1 dist-switch\n' ;;
  1.3.6.1.4.1.9.9.23.1.2.1.1.7) printf '.1.3.6.1.4.1.9.9.23.1.2.1.1.7.2.1 Gi1/0/1\n' ;;
  1.3.6.1.4.1.9.9.23.1.2.1.1.8) printf '.1.3.6.1.4.1.9.9.23.1.2.1.1.8.2.1 "cisco C9300"\n' ;;
  1.3.6.1.2.1.99.1.1.1.1)  printf '.1.3.6.1.2.1.99.1.1.1.1.1001 8\n.1.3.6.1.2.1.99.1.1.1.1.1002 10\n' ;;
  1.3.6.1.2.1.99.1.1.1.3)  printf '.1.3.6.1.2.1.99.1.1.1.3.1001 0\n.1.3.6.1.2.1.99.1.1.1.3.1002 0\n' ;;
  1.3.6.1.2.1.99.1.1.1.4)  printf '.1.3.6.1.2.1.99.1.1.1.4.1001 42\n.1.3.6.1.2.1.99.1.1.1.4.1002 3000\n' ;;
  1.3.6.1.2.1.99.1.1.1.6)  printf '.1.3.6.1.2.1.99.1.1.1.6.1001 1\n.1.3.6.1.2.1.99.1.1.1.6.1002 3\n' ;;
  1.3.6.1.2.1.47.1.1.1.1.7) printf '.1.3.6.1.2.1.47.1.1.1.1.7.1001 "Temp: Inlet"\n.1.3.6.1.2.1.47.1.1.1.1.7.1002 "Fan: Chassis"\n' ;;
  1.3.6.1.2.1.15.3.1.2)    printf '.1.3.6.1.2.1.15.3.1.2.10.0.0.9 6\n.1.3.6.1.2.1.15.3.1.2.10.0.0.10 3\n' ;;
  1.3.6.1.2.1.15.3.1.9)    printf '.1.3.6.1.2.1.15.3.1.9.10.0.0.9 65001\n.1.3.6.1.2.1.15.3.1.9.10.0.0.10 65002\n' ;;
  1.3.6.1.2.1.14.10.1.6)   printf '.1.3.6.1.2.1.14.10.1.6.10.0.0.9.0 8\n' ;;
  *) exit 1 ;;
esac
EOF

cat > "$BIN/snmpget" <<'EOF'
#!/bin/sh
oid=$(eval "printf '%s' \"\${$#}\"")
case "$oid" in
  1.3.6.1.2.1.1.5.0) echo "core-switch" ;;
  1.3.6.1.2.1.1.1.0) echo "Cisco IOS Software, C2960 Software" ;;
  1.3.6.1.2.1.1.2.0) echo ".1.3.6.1.4.1.9.1.1208" ;;
  *) exit 1 ;;
esac
EOF

cat > "$BIN/ping" <<'EOF'
#!/bin/sh
printf '2 packets transmitted, 2 packets received, 0%% packet loss\nround-trip min/avg/max = 1.0/2.5/4.0 ms\n'
EOF

cat > "$BIN/curl" <<'EOF'
#!/bin/sh
# Save the -d payload to a numbered file; always succeed.
n=0; while [ -f "$STUB_OUT/$n.json" ]; do n=$((n+1)); done
while [ $# -gt 0 ]; do case "$1" in -d) shift; printf '%s' "$1" > "$STUB_OUT/$n.json" ;; esac; shift; done
EOF

chmod +x "$BIN"/*
rm -f /tmp/ndm-stub-count
rm -rf /tmp/ndm-state /tmp/ndm-discovery /tmp/ndm-config   # fixed in-script /tmp paths persist between runs

# Render the chart and extract the poller script.
helm template owlpane . -n owlpane \
  --set endpoint=https://ingest.example.com --set cluster.name=test --set ndm.enabled=true \
  --set ndm.intervalSeconds=1 \
  --set-json 'ndm.devices=[{"name":"core-switch","host":"10.0.0.2","communitySecret":{"name":"ndm-core","key":"community"}}]' \
  > "$OUT/render.yaml"
awk '/^  poll-devices\.sh: \|/{f=1;next} /^---/{f=0} f' "$OUT/render.yaml" | sed 's/^    //' > "$OUT/poll-devices.sh"
sh -n "$OUT/poll-devices.sh"

export STUB_OUT="$OUT"
export PATH="$BIN:$PATH"
export OWLPANE_INGEST_KEY="test-key"
export NDM_DEV_1_NAME="core-switch" NDM_DEV_1_HOST="10.0.0.2" NDM_DEV_1_VERSION="v2c" NDM_DEV_1_COMMUNITY="public"

sh "$OUT/poll-devices.sh" & pid=$!
sleep 4
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

python3 - "$OUT" <<'PY'
import json, sys, glob, os
out = sys.argv[1]
files = sorted(glob.glob(os.path.join(out, "*.json")), key=lambda f: int(os.path.basename(f).split(".")[0]))
assert len(files) >= 4, f"expected >=4 payloads (2 cycles x metrics+logs), got {len(files)}"
metrics_seen = {}
sensor_attrs = []
bgp_dps = []
inventory_seen = False
neighbors = []
bgp_events = []
for f in files:
    doc = json.load(open(f))  # raises on invalid JSON
    if "resourceMetrics" in doc:
        for m in doc["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]:
            for dp in m["gauge"]["dataPoints"]:
                attrs = {a["key"]: a["value"]["stringValue"] for a in dp["attributes"]}
                metrics_seen.setdefault(m["name"], set()).add(attrs.get("network.interface.name", "-"))
                if m["name"] == "snmp.sensor.value":
                    sensor_attrs.append((attrs.get("owlpane.ndm.sensor.name"), attrs.get("owlpane.ndm.sensor.type"),
                                         attrs.get("owlpane.ndm.sensor.status"), dp["asDouble"]))
                if m["name"] == "snmp.bgp.peer.state":
                    bgp_dps.append((attrs.get("bgp.peer.ip"), attrs.get("bgp.peer.remote_as"), dp["asDouble"]))
    if "resourceLogs" in doc:
        for rec in doc["resourceLogs"][0]["scopeLogs"][0]["logRecords"]:
            attrs = {a["key"]: a["value"]["stringValue"] for a in rec["attributes"]}
            if attrs.get("owlpane.ndm.kind") == "neighbor":
                neighbors.append(attrs)
            if attrs.get("owlpane.ndm.kind") == "bgp-peer":
                bgp_events.append(attrs)
            if attrs.get("owlpane.ndm.name") == "core-switch" and attrs.get("owlpane.ndm.up") == "true":
                assert attrs.get("owlpane.ndm.vendor") == "cisco", attrs
                inventory_seen = True
expected = {"owlpane.ping.rtt", "owlpane.ping.loss", "snmp.if.in_bps", "snmp.if.out_bps",
            "snmp.if.utilization_pct", "snmp.if.status", "snmp.cpu.util",
            "snmp.sensor.value", "snmp.sensor.status", "snmp.bgp.peer.state", "snmp.ospf.neighbor.state"}
missing = expected - set(metrics_seen)
assert not missing, f"missing metrics: {missing}"
assert "eth0" in metrics_seen["snmp.if.in_bps"], metrics_seen["snmp.if.in_bps"]
assert inventory_seen, "no inventory log for core-switch"
# LLDP neighbor: local Gi0/0 -> edge-router Gi0/1
lldp = [n for n in neighbors if n.get("owlpane.ndm.protocol") == "lldp"]
assert lldp and lldp[0]["owlpane.ndm.remote_name"] == "edge-router", neighbors
assert lldp[0]["owlpane.ndm.local_port"] == "Gi0/0" and lldp[0]["owlpane.ndm.remote_port"] == "Gi0/1", lldp[0]
# CDP neighbor: ifIndex 2 -> eth1 -> dist-switch, platform decoded
cdp = [n for n in neighbors if n.get("owlpane.ndm.protocol") == "cdp"]
assert cdp and cdp[0]["owlpane.ndm.remote_name"] == "dist-switch", neighbors
assert cdp[0]["owlpane.ndm.local_port"] == "eth1" and "C9300" in cdp[0]["owlpane.ndm.remote_platform"], cdp[0]
# Sensors: celsius temp ok=42, rpm fan nonoperational=3000
smap = {s[0]: s for s in sensor_attrs}
assert smap["Temp: Inlet"][1:] == ("celsius", "ok", 42), sensor_attrs
assert smap["Fan: Chassis"][1:] == ("rpm", "nonoperational", 3000), sensor_attrs
# BGP: both peers reported as metrics with remote AS; only the non-established one logged an event
bmap = {b[0]: b for b in bgp_dps}
assert bmap["10.0.0.9"][1:] == ("65001", 6) and bmap["10.0.0.10"][1:] == ("65002", 3), bgp_dps
assert bgp_events and all(e["bgp.peer.ip"] == "10.0.0.10" for e in bgp_events), bgp_events
print(f"PASS: {len(files)} valid OTLP payloads; metrics: {sorted(metrics_seen)}; inventory OK (vendor=cisco); "
      f"neighbors: {len(neighbors)} (lldp+cdp); sensors: {sorted(smap)}; bgp peers: {sorted(bmap)}")
PY

# --- Discovery script: render with discovery enabled, run one sweep against stubs ---
DOUT="$(mktemp -d)"
[ "${NDM_TEST_KEEP:-}" = "1" ] || trap 'rm -rf "$BIN" "$OUT" "$DOUT"' EXIT
helm template owlpane . -n owlpane \
  --set endpoint=https://ingest.example.com --set cluster.name=test --set ndm.enabled=true \
  --set ndm.discovery.enabled=true --set ndm.discovery.cidr=10.0.0.0/30 \
  --set ndm.discovery.intervalSeconds=60 --set ndm.discovery.ratePerSecond=1000 \
  --set ndm.discovery.communitySecret.name=ndm-disc --set ndm.discovery.communitySecret.key=community \
  > "$DOUT/render.yaml"
awk '/^  discover-subnet\.sh: \|/{f=1;next} f && /^  [a-z]/{f=0} f' "$DOUT/render.yaml" | sed 's/^    //' > "$DOUT/discover-subnet.sh"
sh -n "$DOUT/discover-subnet.sh"
export STUB_OUT="$DOUT"
export NDM_DISCOVERY_COMMUNITY="public"
sh "$DOUT/discover-subnet.sh" & pid=$!
sleep 3
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
python3 - "$DOUT" <<'PY'
import json, sys, glob, os
out = sys.argv[1]
files = sorted(glob.glob(os.path.join(out, "*.json")), key=lambda f: int(os.path.basename(f).split(".")[0]))
assert files, "discovery produced no payloads"
found, audit = [], None
for f in files:
    doc = json.load(open(f))
    for rec in doc["resourceLogs"][0]["scopeLogs"][0]["logRecords"]:
        attrs = {a["key"]: a["value"]["stringValue"] for a in rec["attributes"]}
        if attrs.get("owlpane.ndm.kind") == "discovered":
            found.append(attrs)
        if attrs.get("owlpane.ndm.kind") == "discovery-run":
            audit = attrs
assert len(found) == 2, f"expected 2 hosts from /30, got {len(found)}"
assert all(x["owlpane.ndm.snmp"] == "true" and x["owlpane.ndm.sysname"] == "core-switch" for x in found), found
assert all(x["owlpane.ndm.vendor"] == "cisco" for x in found), found
assert audit and audit["owlpane.ndm.cidr"] == "10.0.0.0/30" and audit["owlpane.ndm.up"] == "2", audit
print(f"PASS: discovery sweep — {len(found)} hosts discovered (snmp, vendor=cisco), audit run logged")
PY

# --- Config backup: stub sshpass to emit a canned config, run two cycles, expect one version ---
COUT="$(mktemp -d)"
[ "${NDM_TEST_KEEP:-}" = "1" ] || trap 'rm -rf "$BIN" "$OUT" "$DOUT" "$COUT"' EXIT
cat > "$BIN/sshpass" <<'EOF'
#!/bin/sh
# Ignore all args; emit a canned running-config with credentials that must be redacted.
cat <<'CFG'
hostname core-switch
enable secret 5 $1$abc$defsecret
snmp-server community SECRETCOMM RO
ip ospf message-digest-key 1 md5 MYOSPFKEY
interface GigabitEthernet0/1
 description uplink
CFG
EOF
chmod +x "$BIN/sshpass"
helm template owlpane . -n owlpane \
  --set endpoint=https://ingest.example.com --set cluster.name=test --set ndm.enabled=true \
  --set ndm.configBackup.enabled=true --set ndm.configBackup.intervalSeconds=1 \
  --set-json 'ndm.devices=[{"name":"core-switch","host":"10.0.0.2","communitySecret":{"name":"ndm-core","key":"community"},"configBackup":{"sshSecret":{"name":"ndm-ssh","userKey":"username","passwordKey":"password"}}}]' \
  > "$COUT/render.yaml"
awk '/^  backup-config\.sh: \|/{f=1;next} f && /^  [a-z]/{f=0} f' "$COUT/render.yaml" | sed 's/^    //' > "$COUT/backup-config.sh"
sh -n "$COUT/backup-config.sh"
export STUB_OUT="$COUT"
export NDM_DEV_1_NAME="core-switch" NDM_DEV_1_HOST="10.0.0.2"
export NDM_DEV_1_SSHUSER="admin" NDM_DEV_1_SSHPASS="s3cret" NDM_DEV_1_CONFIGCMD="show running-config"
sh "$COUT/backup-config.sh" & pid=$!
sleep 3
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
python3 - "$COUT" <<'PY'
import json, sys, glob, os
out = sys.argv[1]
files = sorted(glob.glob(os.path.join(out, "*.json")), key=lambda f: int(os.path.basename(f).split(".")[0]))
assert files, "config backup produced no payloads"
configs = []
for f in files:
    doc = json.load(open(f))
    for rec in doc["resourceLogs"][0]["scopeLogs"][0]["logRecords"]:
        attrs = {a["key"]: a["value"]["stringValue"] for a in rec["attributes"]}
        if attrs.get("owlpane.ndm.kind") == "config":
            configs.append((attrs, rec["body"]["stringValue"]))
assert len(configs) == 1, f"unchanged config must not create new versions, got {len(configs)}"
attrs, body = configs[0]
assert attrs["owlpane.ndm.name"] == "core-switch" and attrs["owlpane.ndm.config.version"], attrs
assert "hostname core-switch" in body and "interface GigabitEthernet0/1" in body
for leaked in ("SECRETCOMM", "$1$abc$defsecret", "MYOSPFKEY"):
    assert leaked not in body, f"credential material leaked: {leaked}"
assert body.count("***") >= 3, body
print(f"PASS: config backup — 1 version ({attrs['owlpane.ndm.config.version']}), credentials redacted, no dup on unchanged")
PY
