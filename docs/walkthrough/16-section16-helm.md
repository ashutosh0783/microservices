# Chapter 16: Deep dive on Helm (`section_16/helm-new/`)

> **Verification note:** `helm` is not installed on this machine and no cluster is enabled, so I did not render or install these charts. This is a walkthrough of the chart files as written. Install Helm
> (`winget install Helm.Helm`) and run `helm template` to render them without a cluster.

## 1. The problem
After chapter 15 we have ~8 near-identical Kubernetes YAML files. Now imagine 3 environments (dev, QA, prod), each needing different values: different profile, replicas, image tags, endpoints.
That's ~24 files where 90% is copy-paste. One change ("add an environment variable everywhere") means editing dozens of files, and forgetting one causes a production-only bug.

## 2. The idea: templates + values = manifests
**Helm** is the package manager for Kubernetes. A **chart** is a folder of **templates** (YAML with placeholders) plus a **`values.yaml`** with the actual values:

```
templates/deployment.yaml   (has  {{ .Values.replicaCount }} placeholders)
        +
values.yaml                 (replicaCount: 3)
        │   helm install / helm template
        ▼
plain Kubernetes YAML  ──►  applied to the cluster   (a tracked, versioned "release")
```
Extras Helm gives you: **release tracking** (`helm list`), **upgrade/rollback** (`helm rollback`), **dependencies** between charts, and a huge ecosystem of ready-made charts (Kafka, Keycloak, Grafana…).

**Template syntax cheat sheet** (Go templates):

| Syntax | Meaning |
|--------|---------|
| `{{ .Values.x }}` | Read a value from `values.yaml` (or an override) |
| `{{- if .Values.flag }} … {{- end }}` | Include a block only if the flag is true. The `-` trims whitespace |
| `{{- define "name" -}} … {{- end -}}` | Define a **reusable named template** |
| `{{- template "name" . -}}` | **Insert** that named template; the trailing `.` passes the current context (all values) along |

## 3. Code walkthrough
Folder layout of `section_16/helm-new/` (the refreshed version; `helm/` is the older one):

```
helm-new/
├── eazybank-common/            ← a shared "library" chart holding the reusable templates
├── eazybank-services/          ← one small chart per microservice
│   ├── accounts/  cards/  loans/  configserver/  eurekaserver/  gatewayserver/  message/
├── environments/               ← "umbrella" charts: one per environment
│   ├── dev-env/  qa-env/  prod-env/
└── keycloak/ kafka/ grafana/ grafana-loki/ grafana-tempo/ grafana-alloy/ kube-prometheus/   ← infrastructure charts
```
**The design in one sentence:** write the Deployment/Service/ConfigMap template **once** in `eazybank-common`; each service chart just supplies **values**; each environment chart assembles services and supplies environment-wide **global** values.

### 3.1 The reusable Deployment template: `eazybank-common/templates/deployment.yaml`
```yaml
1  {{- define "common.deployment" -}}
2  apiVersion: apps/v1
3  kind: Deployment
4  metadata:
5    name: {{ .Values.deploymentName }}
6    labels:
7      app: {{ .Values.appLabel }}
8  spec:
9    replicas: {{ .Values.replicaCount }}
10   selector:
11     matchLabels:
12       app: {{ .Values.appLabel }}
13   template:
14     metadata:
15       labels:
16         app: {{ .Values.appLabel }}
17     spec:
18       containers:
19       - name: {{ .Values.appLabel }}
20         image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
21         ports:
22         - containerPort: {{ .Values.containerPort }}
23           protocol: TCP
24         env:
25         {{- if .Values.appname_enabled }}
26         - name: SPRING_APPLICATION_NAME
27           value: {{ .Values.appName }}
28         {{- end }}
29         {{- if .Values.profile_enabled }}
30         - name: SPRING_PROFILES_ACTIVE
31           valueFrom:
32             configMapKeyRef:
33               name: {{ .Values.global.configMapName }}
34               key: SPRING_PROFILES_ACTIVE
35         {{- end }}
36         {{- if .Values.config_enabled }}
37         - name: SPRING_CONFIG_IMPORT
...
43         {{- if .Values.eureka_enabled }}
44         - name: EUREKA_CLIENT_SERVICEURL_DEFAULTZONE
...
50         {{- if .Values.resouceserver_enabled }}
51         - name: SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK-SET-URI
...
57         {{- if .Values.otel_enabled }}
58         - name: JAVA_TOOL_OPTIONS ... OTEL_EXPORTER_OTLP_ENDPOINT ... OTEL_METRICS_EXPORTER ... OTEL_LOGS_EXPORTER ...
78         - name: OTEL_SERVICE_NAME
79           value: {{ .Values.appName }}
80         {{- end }}
81         {{- if .Values.kafka_enabled }}
82         - name: SPRING_CLOUD_STREAM_KAFKA_BINDER_BROKERS
...
87         {{- end }}
89 {{- end -}}
```
Compare with chapter 15's `5_accounts.yml`: same Deployment, but every environment-specific piece became a placeholder.
- **Line 1, `define "common.deployment"`**: this file doesn't produce a Deployment by itself; it **defines a named template** other charts can call. (The chart is typed `application` in `Chart.yaml` but works as a shared template library.)
- **Lines 5, 7, 9, 12, 16, 19, 22**: names, replica count, labels, container port. All from `.Values.*`. **Note lines 12 and 16 use the same `appLabel`**, which guarantees the selector/labels match automatically (the mismatch bug from chapter 15 can't happen).
- **Line 20**: image = `repository:tag`, e.g. `eazybytes/accounts` + `s14` → `eazybytes/accounts:s14`. Promoting a new version means changing one `tag` value.
- **Lines 25–87, feature flags**: `{{- if .Values.eureka_enabled }}` includes the Eureka variable **only for services that need it**. That's how one template serves all services: the `configserver` sets `config_enabled: false`
  (it doesn't fetch config from itself), `message` turns almost everything off (`profile`, `config`, `eureka` and `otel` are all `false`; only `kafka_enabled: true`), which matches chapter 13/14 where it has no config import or registration, and only the gateway sets `resouceserver_enabled: true`. (*The spelling `resouceserver` is the project's own typo; it's consistent everywhere, so it works, but grep carefully.*)
- **Lines 33 etc., `.Values.global.configMapName`**: **`global` is a special values key**: values under `global:` are visible to a chart *and all its sub-charts*. That's how the environment chart pushes shared settings down into every service. See 3.4.

`eazybank-common/templates/service.yaml`:
```yaml
1  {{- define "common.service" -}}
2  apiVersion: v1
3  kind: Service
4  metadata:
5    name: {{ .Values.serviceName }}
6  spec:
7    selector:
8      app: {{ .Values.appLabel }}
9    type: {{ .Values.service.type }}
10   ports:
11     - name: http
12       protocol: TCP
13       port: {{ .Values.service.port }}
14       targetPort: {{ .Values.service.targetPort }}
15 {{- end -}}
```
- Same idea: **line 5** name, **line 8** the selector (same `appLabel` as the Deployment, so they always line up), **line 9** the type (`ClusterIP`/`LoadBalancer`), **lines 13–14** ports.

`eazybank-common/templates/configmap.yaml` **defines the environment's ConfigMap once**:
```yaml
1  {{- define "common.configmap" -}}
2  apiVersion: v1
3  kind: ConfigMap
4  metadata:
5    name: {{ .Values.global.configMapName }}
6  data:
7    SPRING_PROFILES_ACTIVE: {{ .Values.global.activeProfile }}
8    SPRING_CONFIG_IMPORT: {{ .Values.global.configServerURL }}
9    EUREKA_CLIENT_SERVICEURL_DEFAULTZONE: {{ .Values.global.eurekaServerURL }}
10   SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK-SET-URI: {{ .Values.global.keyCloakURL }}
11   JAVA_TOOL_OPTIONS: {{ .Values.global.openTelemetryJavaAgent }}
12   OTEL_EXPORTER_OTLP_ENDPOINT: {{ .Values.global.otelExporterEndPoint }}
13   OTEL_METRICS_EXPORTER: {{ .Values.global.otelMetricsExporter }}
14   OTEL_LOGS_EXPORTER: {{ .Values.global.otelLogsExporter }}
15   SPRING_CLOUD_STREAM_KAFKA_BINDER_BROKERS: {{ .Values.global.kafkaBrokerURL }}
16 {{- end -}}
```
This ConfigMap has **exactly** the keys the Deployment template's `configMapKeyRef`s read. Every setting from chapters 6–14 (profile, config server, Eureka, JWKS, OpenTelemetry, Kafka) is now a value.

### 3.2 A service chart is almost empty: `eazybank-services/accounts/`
`Chart.yaml` (comments removed):
```yaml
1  apiVersion: v2
2  name: accounts
3  type: application
4  version: 0.1.0
5  appVersion: "1.0.0"
6  dependencies:
7    - name: eazybank-common
8      version: 0.1.0
9      repository: file://../../eazybank-common
```
- **Lines 6–9, `dependencies`**: this chart *depends on* the common chart, found on the local filesystem (`file://` relative path). `helm dependency build` packs it into `charts/eazybank-common-0.1.0.tgz`. (That's the `.tgz` in each service's `charts/` folder, plus a `Chart.lock`.)
- `version` is the **chart** version; `appVersion` is informational, the app version.

`templates/deployment.yaml` and `templates/service.yaml` are **one line each**:
```yaml
{{- template "common.deployment" . -}}
{{- template "common.service" . -}}
```
Each service chart says "render the common Deployment (or Service) using *my* values". This is the entire per-service YAML.

`values.yaml` is where a service is actually defined:
```yaml
1  deploymentName: accounts-deployment
2  serviceName: accounts
3  appLabel: accounts
4  appName: accounts
6  replicaCount: 1
8  image:
9    repository: eazybytes/accounts
10   tag: s14
12 containerPort: 8080
14 service:
15   type: ClusterIP
16   port: 8080
17   targetPort: 8080
19 appname_enabled: true
20 profile_enabled: true
21 config_enabled: true
22 eureka_enabled: true
23 resouceserver_enabled: false
24 otel_enabled: true
25 kafka_enabled: true
```
- **Lines 1–4, 8–12, 14–17**: identity, image (`s14`), ports, Service type (`ClusterIP`: internal only, the safe default; the gateway would be the exposed one).
- **Lines 19–25**: the **feature flags** from 3.1. Accounts needs the app name, profile, config server, Eureka, OpenTelemetry **and Kafka** (it publishes events), but **not** the resource-server (JWKS) setting.
- Adding a new microservice = copy this folder, change these ~15 values. Compare that to writing a new 55-line YAML by hand.

### 3.3 The environment chart: `environments/dev-env/`
`Chart.yaml` (dependencies):
```yaml
6  dependencies:
7    - name: eazybank-common
8      version: 0.1.0
9      repository: file://../../eazybank-common
11   - name: configserver
12     version: 0.1.0
13     repository: file://../../eazybank-services/configserver
15   - name: eurekaserver ...
19   - name: accounts ...
23   - name: cards ...
27   - name: loans ...
31   - name: gatewayserver ...
35   - name: message ...
```
An **umbrella chart**: it has no application of its own, only a **list of dependencies** = the set of services that make up "dev". One `helm install` deploys all eight, in one release.

`templates/configmap.yaml`: one line, `{{- template "common.configmap" . -}}`: renders the shared ConfigMap for this environment.

`values.yaml` supplies the **`global`** block:
```yaml
1  global:
2    configMapName: eazybankdev-configmap
3    activeProfile: default
4    configServerURL: configserver:http://configserver:8071/
5    eurekaServerURL: http://eurekaserver:8070/eureka/
6    keyCloakURL: http://keycloak.default.svc.cluster.local:80/realms/master/protocol/openid-connect/certs
7    openTelemetryJavaAgent: "-javaagent:/app/libs/opentelemetry-javaagent-2.22.0.jar"
8    otelExporterEndPoint: http://tempo.default.svc.cluster.local:4318
9    otelMetricsExporter: none
10   otelLogsExporter: none
11   kafkaBrokerURL: kafka-controller-0.kafka-controller-headless.default.svc.cluster.local:9092
```
- **Line 3, `activeProfile: default`**: this is what differs per environment. `qa-env/values.yaml` says `qa`, and `prod-env` says `prod`. The ConfigMap name differs per environment too (`eazybankdev-configmap`, `eazybankqa-configmap`, `eazybankprod-configmap`), so environments can share a namespace without clashing. **One value flips the whole environment's config**, since the services fetch `*-qa.yml` or `*-prod.yml` from the Config Server (chapter 6).
- **Lines 6, 8, 11**: cluster-internal DNS names: `<service>.<namespace>.svc.cluster.local`. Keycloak, Tempo and Kafka here come from **other Helm charts** (`helm-new/keycloak`, `grafana-tempo`, `kafka`), which install the infrastructure.
- **Line 7**: the `/app/libs/…` path from chapter 11, now injected as `JAVA_TOOL_OPTIONS` for every service that has `otel_enabled: true`.

**The value flow in one picture:**
```
environments/dev-env/values.yaml : global.activeProfile=default
        │  (global values propagate down to every sub-chart)
        ▼
eazybank-common/templates/configmap.yaml    → ConfigMap "eazybankdev-configmap"
eazybank-services/accounts/values.yaml (tag s14, ports, flags)
        │ + eazybank-common/templates/deployment.yaml
        ▼
Deployment "accounts-deployment"  env: SPRING_PROFILES_ACTIVE ← configMapKeyRef → eazybankdev-configmap
```

## 4. Try it (needs `helm`; a cluster is optional for `template`)
```bash
cd section_16/helm-new/environments/dev-env
helm dependency build                      # packs the service charts into charts/
helm template eazybank . | less            # render ALL the YAML locally; no cluster needed. Best learning tool
helm install eazybank .                    # deploy (needs a cluster)
helm list                                  # releases
helm upgrade eazybank . --set accounts.replicaCount=3    # override one value at upgrade time
helm rollback eazybank 1                   # go back to revision 1
helm uninstall eazybank
```
Try `helm template` first: change `activeProfile` to `prod`, re-render and see the ConfigMap change, or set `otel_enabled: false` on a service and watch the `OTEL_*` variables vanish from its Deployment.

## 5. Traps and senior notes
- **Whitespace is syntax in YAML.** `{{-` (with a dash) trims the newline before the tag; get it wrong and the YAML is mis-indented. `helm template` and `helm lint` catch this before a cluster does.
- **Flag explosion.** Every `xxx_enabled` flag is a small smell: the template is growing options. Past ~10 flags, teams split templates or use `range` loops over a map. It's fine here.
- **Pin versions.** `tag: s14` is explicit. Never use `latest` in a chart.
- **Umbrella charts couple releases.** Deploying all services together means you can't easily roll back just one. Many organisations instead give each service its own release and CI/CD pipeline.
- **`helm/` vs `helm-new/`:** both exist in this repo. `helm-new/` adds `grafana-alloy` and uses the newer layout; prefer it.
- **Secrets in values files are a leak.** Use sealed-secrets, SOPS or an external secrets operator for real credentials.
