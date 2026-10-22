# Runtime telemetry via the Owlpane agent

Cluster workloads instrumented through the Helm chart can feed **Observability → Runtimes** in the console without custom Owlpane SDK code in every image.

## Data path

```
Pod (OTel auto-instrumentation) → node agent :4318 (OTLP) → Owlpane ingest → ClickHouse → API menu-dashboards
```

## Enable auto-instrumentation

In `values.yaml`:

```yaml
autoInstrumentation:
  enabled: true
  samplerRatio: "1"
nodeAgent:
  enabled: true
  otlpHostPort: true
```

The chart creates an OpenTelemetry Operator `Instrumentation` resource (`owlpane`) that sets:

- `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`
- `OTEL_METRICS_EXPORTER=otlp` (required for runtime vitals/charts)
- `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/protobuf`
Requires the [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator) installed in the cluster.

## Opt-in on a Deployment

```yaml
metadata:
  annotations:
    instrumentation.opentelemetry.io/inject-java: "owlpane/owlpane"
```

Replace `inject-java` with `inject-nodejs`, `inject-python`, `inject-dotnet`, or `inject-go` as appropriate. Namespace must match the Helm release namespace.

## Resource attributes

Ensure pods set or inherit:

- `deployment.environment.name` (often from `OTEL_RESOURCE_ATTRIBUTES` or the node agent `resourcedetection` processor)
- `telemetry.sdk.language` (set by language instrumentation)
- `service.name` (from `OTEL_SERVICE_NAME` or K8s metadata)

## What the console shows

Per language slug: RED cards, slowest operations, top errors, dependencies, workload split time series (HTTP vs queue), and runtime metric charts when OTLP metrics are present.

Full metric names and span conventions: [owlpane-sdk `docs/runtime-telemetry.md`](https://github.com/OwlPane/owlpane-sdk/blob/main/docs/runtime-telemetry.md) (or monorepo `sdk/docs/runtime-telemetry.md`).

## Host / VM workloads

For processes outside Kubernetes, export OTLP directly to your Owlpane ingest URL or to a standalone collector configured in `values-standalone.yaml`. See [host-otel.md](./host-otel.md).
