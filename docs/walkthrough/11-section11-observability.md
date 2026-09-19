# Chapter 11: Observability and monitoring (`section_11/`, final form in `section_14/`)

New in this section: the whole `docker-compose/observability/` folder, the Micrometer and OpenTelemetry dependencies, the log pattern that carries trace ids, and ten new containers
(Grafana, Loki ×3, Alloy, nginx, MinIO, Prometheus, Tempo).

## 1. The problem
With one monolith you `ssh` in and read one log file. With 8 services in 8 containers, possibly 3 copies each:
- Which container logged the error? Which *request* was it part of?
- Is the system getting slower? Which service is the bottleneck?
- "It was slow at 14:02": where did those 4 seconds go?

You can't debug a distributed system by reading files. You need to **observe** it from the outside.

## 2. The idea: three pillars, one dashboard

| Pillar | Question | Data | Tool here |
|--------|----------|------|-----------|
| **Logs** | *What happened?* | Text events | **Alloy** collects, **Loki** stores |
| **Metrics** | *How is it doing?* | Numbers over time (requests/s, memory, error rate) | **Micrometer** exposes, **Prometheus** scrapes |
| **Traces** | *Where did this one request spend its time?* | A tree of timed **spans** across services | **OpenTelemetry** agent produces, **Tempo** stores |
| (UI) | | | **Grafana** queries all three |

```
 service stdout ──► Alloy ──► nginx gateway ──► Loki write ──► MinIO (object storage) ◄── Loki read ◄──┐
 /actuator/prometheus ◄── Prometheus (pulls every 5 s) ─────────────────────────────────────────────────┼──► Grafana
 OpenTelemetry Java agent ──OTLP :4318──► Tempo ─────────────────────────────────────────────────────────┘
```
Key terms: a **trace** is one request's whole journey; a **span** is one step within it (gateway hop, accounts handler, a DB call); the **trace id** is the id shared by all spans of that journey.
Correlation id (chapter 9) was our homemade version; the trace id is the industry-standard one.

## 3. Code walkthrough

### 3.1 Metrics: Micrometer and Prometheus
`pom.xml` (every service):
```xml
1  <dependency>
2      <groupId>org.springframework.boot</groupId>
3      <artifactId>spring-boot-starter-actuator</artifactId>
4  </dependency>
5  <dependency>
6      <groupId>io.opentelemetry.javaagent</groupId>
7      <artifactId>opentelemetry-javaagent</artifactId>
8      <version>${otelVersion}</version>
9      <scope>runtime</scope>
10 </dependency>
11 <dependency>
12     <groupId>io.micrometer</groupId>
13     <artifactId>micrometer-registry-prometheus</artifactId>
14 </dependency>
```
- **Lines 1–4, Actuator** is the source of `/actuator/*`. **Lines 11–14, `micrometer-registry-prometheus`** adds **`/actuator/prometheus`**, which prints all metrics in Prometheus' text format
  (JVM memory, HTTP request timings, Kafka, DB pool…). **Micrometer** is the "SLF4J for metrics": your code talks to Micrometer, and a registry adapts it to a backend.
- **Lines 5–10**: notice the OpenTelemetry **agent is added as an ordinary Maven dependency** with `runtime` scope. Jib puts all dependencies under `/app/libs`, so the agent jar lands at
  `/app/libs/opentelemetry-javaagent-2.22.0.jar`, and that exact path is used in 3.3. Clever: no extra download or Dockerfile step.

The tag in `application.yml`:
```yaml
1  management:
2    metrics:
3      tags:
4        application: ${spring.application.name}
```
- Every metric gets an `application="accounts"` label, so a Grafana dashboard can filter by service.

`docker-compose/observability/prometheus/prometheus.yml`:
```yaml
1  global:
2    scrape_interval:     5s
3    evaluation_interval: 5s
5  scrape_configs:
6    - job_name: 'accounts'
7      metrics_path: '/actuator/prometheus'
8      static_configs:
9        - targets: [ 'accounts:8080' ]
10   - job_name: 'loans'
11     metrics_path: '/actuator/prometheus'
12     static_configs:
13       - targets: [ 'loans:8090' ]
... (cards:9000, gatewayserver:8072, eurekaserver:8070, configserver:8071)
```
- **Prometheus is pull-based**: **Line 2**: every 5 s it *fetches* each target's metrics URL. (Push-based systems require every app to know where to send data.)
- **Line 9**: targets are `service-name:port` on the Docker network, as everywhere else.
- Verified on the running stack: `http://localhost:9090/api/v1/targets` lists all six jobs as `up`.
- A useful first query in Prometheus/Grafana: `http_server_requests_seconds_count`, or `rate(http_server_requests_seconds_count[1m])` for requests per second.

### 3.2 Logs: pattern, Alloy, Loki
The log pattern, in every service's `application.yml`:
```yaml
1  logging:
2    pattern:
3      level: "%5p [${spring.application.name},%X{trace_id},%X{span_id}]"
```
- `%5p` is the level (INFO/WARN…, padded to 5). `%X{trace_id}` reads the **MDC**, a per-thread key/value map. The OpenTelemetry agent puts `trace_id` and `span_id` in it for each request, so
  **every log line automatically ends up looking like** `INFO [accounts,9943240427685801f80354e5be501eb6,60cd1f004f3b9d4b] ...`. That's a line we really captured from `accounts-ms`.
  Outside a request (startup, background threads) the ids are empty: `[accounts,,]`.

`observability/alloy/alloy-local-config.yaml` (**Alloy** is Grafana's collector agent):
```
1  discovery.docker "flog_scrape" {
2  	host             = "unix:///var/run/docker.sock"
3  	refresh_interval = "5s"
4  }
6  discovery.relabel "flog_scrape" {
7  	targets = []
9  	rule {
10 		source_labels = ["__meta_docker_container_name"]
11 		regex         = "/(.*)"
12 		target_label  = "container"
13 	}
14 }
16 loki.source.docker "flog_scrape" {
17 	host             = "unix:///var/run/docker.sock"
18 	targets          = discovery.docker.flog_scrape.targets
19 	forward_to       = [loki.write.default.receiver]
20 	relabel_rules    = discovery.relabel.flog_scrape.rules
21 	refresh_interval = "5s"
22 }
24 loki.write "default" {
25 	endpoint {
26 		url       = "http://gateway:3100/loki/api/v1/push"
27 		tenant_id = "tenant1"
28 	}
29 	external_labels = {}
30 }
```
This is a small **pipeline** language: *discover → relabel → read → write*.
- **Lines 1–4**: talk to the Docker daemon through its socket (compose mounts `/var/run/docker.sock` into the Alloy container) to **discover every running container** and re-check every 5 s.
- **Lines 9–13**: Docker names containers `/accounts-ms`; this rule strips the leading `/` with a regex and stores it as label **`container`**. That's why in Grafana you query `{container="accounts-ms"}`
  (the datasource also exposes `service_name`, and I used `{service_name="accounts-ms"}` successfully).
- **Lines 16–22**: read each container's **stdout/stderr** log stream and hand it to the writer. This is the 12-factor rule "logs are a stream": apps just print, the platform ships.
- **Lines 24–29**: push to Loki at `http://gateway:3100/...`. Here `gateway` is **nginx**, not the Spring gateway (unlucky naming!). **Line 27**: `tenant_id = "tenant1"`, Loki is multi-tenant, so every request must say which tenant it is.
  Grafana's Loki datasource sends the same tenant as a header `X-Scope-OrgID: tenant1`; that's why a plain `curl localhost:3100/loki/api/v1/labels` answers *"no org id"* (I got a 401).

`observability/loki/loki-config.yaml` (key parts):
```yaml
5  memberlist:
6    join_members: ["read", "write", "backend"]
13 schema_config:
14   configs:
15     - from: 2023-01-01
16       store: tsdb
17       object_store: s3
18       schema: v13
22 common:
23   path_prefix: /loki
24   replication_factor: 1
25   compactor_address: http://backend:3100
26   storage:
27     s3:
28       endpoint: http://minio:9000
29       insecure: true
30       bucketnames: loki-data
31       access_key_id: loki
32       secret_access_key: supersecret
33       s3forcepathstyle: true
```
- **The same image runs in 3 roles** (`-target=read`, `-target=write`, `-target=backend` in compose): a *simple scalable* deployment. **write** ingests, **read** answers queries, **backend** does housekeeping (compaction).
  They find each other by gossip (`memberlist`, lines 5–6).
- **Lines 15–18**: log chunks and their index are stored as **objects** ("S3"). Locally that S3 is **MinIO** (a self-hosted S3 clone).
- **Line 28 is a bug fixed in this repo.** It used to say `minio:9000`. Loki 3.6's AWS SDK requires a full URI, and logged
  *"Custom endpoint `minio:9000` was not a valid URI"* on every flush. Now `http://minio:9000`.
- **Line 29 `insecure: true`** = plain HTTP inside the private network. **Line 33 `s3forcepathstyle`** = use `http://minio:9000/bucket/…` (MinIO needs it) instead of `bucket.minio` DNS names.
- The **nginx `gateway` container** just routes: pushes (`/loki/api/v1/push`) to `write`, queries to `read`. It is the single URL that Alloy and Grafana use.

### 3.3 Traces: the OpenTelemetry agent and Tempo
`docker-compose/default/common-config.yml`:
```yaml
6  microservice-base-config:
7    extends:
8      service: network-deploy-service
9    deploy:
10     resources:
11       limits:
12         memory: 700m
13   environment:
14     JAVA_TOOL_OPTIONS: "-javaagent:/app/libs/opentelemetry-javaagent-2.22.0.jar"
15     OTEL_EXPORTER_OTLP_ENDPOINT: http://tempo:4318
16     OTEL_METRICS_EXPORTER: none
17     OTEL_LOGS_EXPORTER: none
```
- **Line 14, the magic:** `JAVA_TOOL_OPTIONS` is read by **every JVM at startup**. `-javaagent:` loads the OpenTelemetry agent **before** `main` runs; it rewrites bytecode of Spring MVC, WebFlux, Feign, JDBC,
  Kafka clients… to create spans automatically. **You changed zero Java code.** This is *auto-instrumentation*.
- **Line 15**: where to send spans: Tempo's OTLP-over-HTTP port 4318. **Lines 16–17**: send only traces; metrics and logs travel by their own paths (Prometheus, Alloy), so turn the agent's off to avoid duplicates.
- Each service also sets `OTEL_SERVICE_NAME` (in `docker-compose.yml`, e.g. `OTEL_SERVICE_NAME: "accounts"`); that's the name you pick in Grafana's Tempo search.
- **Junior tip:** at startup you'll see `Picked up JAVA_TOOL_OPTIONS: -javaagent:…` in each container's log: proof the agent loaded.

`observability/tempo/tempo.yml`:
```yaml
1  server:
2    http_listen_port: 3100
3    http_listen_address: 0.0.0.0
5  distributor:
6    receivers:
7      otlp:
8        protocols:
9          grpc:
10           endpoint: 0.0.0.0:4317
11         http:
12           endpoint: 0.0.0.0:4318
14 ingester:
15   trace_idle_period: 10s
19 compactor:
20   compaction:
21     block_retention: 1h
26 storage:
27   trace:
28     backend: local
29     local:
30       path: /tmp/tempo/blocks
```
- **Lines 5–12**: the **receiver**: accepts OTLP spans over gRPC (4317) or HTTP (4318). The agent uses HTTP.
- **Line 15**: a trace is considered "complete" after 10 s with no new spans. **Line 21**: keep traces for **1 hour** only: fine for a lab, tiny for production.
- **Lines 28–30**: store blocks on the container's local disk (lost with the container).

### 3.4 Grafana ties them together: `datasource.yml`
```yaml
 - name: Prometheus  ...  url: http://prometheus:9090
 - name: Tempo       ...  url: http://tempo:3100
 - name: Loki
    type: loki
    uid: loki
    url: http://gateway:3100
    jsonData:
      httpHeaderName1: "X-Scope-OrgID"
      derivedFields:
        - datasourceUid: tempo
          matcherRegex: "\\[.+,(.+),.+\\]"
          name: TraceID
          url: '$${__value.raw}'
    secureJsonData:
      httpHeaderValue1: "tenant1"
```
- **`httpHeaderName1/httpHeaderValue1`**: sends `X-Scope-OrgID: tenant1` so Loki accepts the queries.
- **`derivedFields` is the best trick in the file.** The regex `\[.+,(.+),.+\]` runs on every log line and matches our pattern `[accounts,<trace_id>,<span_id>]`; group 1 (`(.+)`) is the
  trace id. Grafana turns it into a **clickable "TraceID" link that opens that trace in Tempo**. Change the log pattern and this stops working. The two files are coupled.
- Grafana runs with anonymous admin (`GF_AUTH_ANONYMOUS_ENABLED=true`, role `Admin`) in compose: convenient locally, **never** on a shared network.

## 4. Try it and break it (verified on the running stack)
1. `http://localhost:3000` → **Explore** → choose **Loki** → query `{service_name="accounts-ms"}`: you see accounts' log lines with `[accounts,traceid,spanid]`.
2. Make a call: `curl "localhost:8072/eazybank/accounts/api/fetchCustomerDetails?mobileNumber=4354437687"`. Choose **Tempo** → *Search* → service `gatewayserver`. **What I observed for exactly this call:** *one* trace containing spans from **four services**
   (`gatewayserver`, `accounts`, `loans`, `cards`), including `GET` (the gateway hop), `GET /api/fetchCustomerDetails` (accounts), `CustomerRepository.findByMobileNumber` and `AccountsRepository.findByCustomerId` (the DB lookups, auto-instrumented),
   `GET /api/fetch` (the Feign calls arriving at loans and cards) and `CardsRepository.findByMobileNumber`. The waterfall shows which step took the time.
   **Tip:** the list is flooded with `GET /actuator/prometheus` and `/actuator/health/**` traces (Prometheus scrapes every 5 s, Docker health checks run every 20 s). Filter them out with a query like `{ name !~ ".*actuator.*" }`, or search by the span name you care about.
3. From a log line containing a trace id, click **TraceID**; you land on that exact trace.
4. **Prometheus** → `http://localhost:9090/targets`: six green targets. Query `jvm_memory_used_bytes{application="loans"}`.
5. Break it: `docker stop tempo`, and the services keep working; you only lose traces (observability must **never** take down the app). `docker start tempo`.

## 5. Traps and senior notes
- **Cardinality kills metrics systems.** Never put unbounded values (user ids, full URLs) in metric labels.
- **Log lines with secrets or personal data end up in Loki, forever.** Scrub at the source.
- **Sampling:** here every request is traced (fine for a lab). At real traffic you sample (e.g. 1–10%) and keep all errors.
- **The agent adds overhead and memory.** That's part of why each container has a 700 MB limit and you may see slower startup.
- **This stack is heavy** (about 10 of the 18 containers are observability). Production teams usually use a managed service or a shared platform team's stack rather than running it per app.
- **The "unhealthy" Loki read/write containers are a false alarm**: the compose healthcheck runs `/bin/sh`, which the Loki image doesn't contain.
