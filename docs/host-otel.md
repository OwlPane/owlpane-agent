# Host Telemetry Collector (Linux & Windows)

Collect host CPU, memory, disk, filesystem, load, network, process metrics, and host system logs on bare-metal or VM hosts outside Kubernetes using the OpenTelemetry Collector configured for Owlpane.

## 1. Prerequisites

1. Create a project in the Owlpane console (**Setup → Projects & keys**) and copy your `owl_ing_*` ingest key.
2. Install the OpenTelemetry Collector Contrib binary or system package (`otelcol-contrib`) on the target host.

## 2. Environment Variables (`/etc/otelcol-contrib/owlpane.env`)

```bash
OWLPANE_INGEST_URL="https://ingest.owlpane.com"
OWLPANE_INGEST_KEY="owl_ing_REPLACE_WITH_YOUR_KEY"
OWLPANE_ENVIRONMENT="production"
```

For local cell testing, set `OWLPANE_INGEST_URL="http://127.0.0.1:4318"`.

## 3. Collector Configuration (`/etc/otelcol-contrib/config.yaml`)

```yaml
receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu: {}
      disk: {}
      filesystem: {}
      load: {}
      memory: {}
      network: {}
      paging: {}
      processes: {}
  filelog/syslog:
    include:
      - /var/log/syslog
      - /var/log/messages
    start_at: end

processors:
  resourcedetection:
    detectors: [env, system]
    timeout: 5s
  resource/owlpane:
    attributes:
      - key: deployment.environment.name
        value: "${env:OWLPANE_ENVIRONMENT}"
        action: upsert
  batch:
    send_batch_size: 1000
    timeout: 5s

exporters:
  otlphttp/owlpane:
    endpoint: "${env:OWLPANE_INGEST_URL}"
    headers:
      Authorization: "Bearer ${env:OWLPANE_INGEST_KEY}"

service:
  pipelines:
    metrics:
      receivers: [hostmetrics]
      processors: [resourcedetection, resource/owlpane, batch]
      exporters: [otlphttp/owlpane]
    logs:
      receivers: [filelog/syslog]
      processors: [resourcedetection, resource/owlpane, batch]
      exporters: [otlphttp/owlpane]
```

## 4. Matching Starter Dashboards

Once `otelcol-contrib` is running:

1. Verify host metrics under **Infrastructure → Hosts** in the Owlpane console.
2. Open **Dashboards → Library** (`/observability/dashboards/library`) and install the **hostmetrics** or **Windows** starter dashboard pack.
