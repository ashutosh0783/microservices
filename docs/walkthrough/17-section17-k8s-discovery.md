# Chapter 17: Server-side discovery and load balancing with Kubernetes (`section_17/`)

> **Verification note:** as in chapters 15 and 16, this is a walkthrough of the files: no Kubernetes cluster is enabled on this machine, so I didn't deploy it. The code differences below come from a real `diff -r section_14 section_17`.

## 1. The problem
In chapter 8 we built a **discovery system** (Eureka) and taught every service to register and look up others: extra servers, extra libraries, extra config, heartbeats and stale entries. But on Kubernetes,
**the platform already does this**: every `Service` gets a stable DNS name and load balances across its Pods (chapter 15). Running Eureka on top duplicates it, and the two can disagree.

## 2. The idea: client-side vs server-side discovery

| | **Client-side** (chapter 8: Eureka) | **Server-side** (this chapter: Kubernetes) |
|---|---|---|
| Who knows the instances? | Every **caller** downloads the registry | The **platform** (kube-proxy / Service) |
| Who picks an instance? | The caller's load balancer | The platform |
| Caller code | Needs a discovery client + LB library | Just calls a **name** |
| Extra infrastructure | Eureka server | None |
| Language coupling | Library per language (Java-heavy) | Any language works |
| Portability | Runs anywhere | Tied to Kubernetes |

Analogy: client-side = *you* call directory enquiries then dial a number yourself; server-side = you dial a company's main number and the switchboard connects you to a free person.

## 3. Code walkthrough: what changed from section 14
Running `diff -r section_14 section_17` (ignoring poms and compose), the changes are:
- the **`eurekaserver` folder is gone**;
- small edits in `accounts`, `loans`, `cards` (`*Application.java`, `application.yml`, Feign clients);
- edits in the gateway (routes and `application.yml`);
- new `kubernetes/kubernetes-discoveryserver.yml`, plus `helm` and `helm-new`.

### 3.1 The Eureka settings are deleted from every service
`accounts/src/main/resources/application.yml`, the diff (lines starting `<` were removed):
```diff
+   kubernetes:
+     discovery:
+       all-namespaces: true
...
- eureka:
-   instance:
-     preferIpAddress: true
-   client:
-     fetchRegistry: true
-     registerWithEureka: true
-     serviceUrl:
-       defaultZone: http://localhost:8070/eureka/
```
- The entire `eureka:` block (register, fetch, defaultZone) is removed: nobody registers anywhere any more. (In `docker-compose`-style flows `EUREKA_CLIENT_SERVICEURL_DEFAULTZONE` is no longer injected either.)
- **`kubernetes.discovery.all-namespaces: true`** is added: this tells the Spring Cloud Kubernetes discovery client to look for services in **every namespace**, not just the app's own.

`AccountsApplication.java` gains one annotation:
```diff
+ import org.springframework.cloud.client.discovery.EnableDiscoveryClient;
  @SpringBootApplication
  @EnableFeignClients
+ @EnableDiscoveryClient
```
- **`@EnableDiscoveryClient`** is Spring Cloud's *generic* "I participate in service discovery" switch. Which system it talks to depends on the dependency on the classpath: in section 8 it was the Eureka client; here it's
  **`spring-cloud-starter-kubernetes-discoveryclient`**. Same annotation, different backend: the abstraction that lets you migrate.

### 3.2 Feign now calls Kubernetes Service names directly
`LoansFeignClient.java`:
```java
2  @FeignClient(name="loans", url = "http://loans:8090",fallback = LoansFallback.class)
3  public interface LoansFeignClient {
4      @GetMapping(value = "/api/fetch",consumes = "application/json")
5      public ResponseEntity<LoansDto> fetchLoanDetails(@RequestHeader("eazybank-correlation-id")
6                                                           String correlationId, @RequestParam String mobileNumber);
7  }
```
- **Line 2**: compare with chapter 8's `@FeignClient("loans")`. Now there's an explicit **`url = "http://loans:8090"`**. When `url` is set, Feign skips the load-balancer lookup and **calls that address directly**.
  `loans` here is the **name of the Kubernetes Service** (chapter 15's `metadata.name: loans`), which cluster DNS resolves. The Service then load balances across the loans Pods. `CardsFeignClient` uses `http://cards:9000`.
- **The fallback, correlation-id header and mapping are unchanged**: resilience (chapter 10) is independent of *how* the address was found.
- **Trade-off:** the address is hard-coded in the source. Nicer approaches read it from config (`url = "${loans.url}"`), especially since it now assumes port 8090 and a Service called `loans`.

### 3.3 The gateway routes to plain URLs
`GatewayserverApplication.java`:
```java
6   .route(p -> p
7       .path("/eazybank/accounts/**")
8       .filters( f -> f.rewritePath("/eazybank/accounts/(?<segment>.*)","/${segment}")
9           .addResponseHeader("X-Response-Time", LocalDateTime.now().toString())
10          .circuitBreaker(config -> config.setName("accountsCircuitBreaker")
11              .setFallbackUri("forward:/contactSupport")))
12      .uri("http://accounts:8080"))
13  .route(p -> p
14      .path("/eazybank/loans/**")
...
20      .uri("http://loans:8090"))
21  .route(p -> p
22      .path("/eazybank/cards/**")
...
28      .uri("http://cards:9000")).build();
```
- **Lines 12, 20, 28**: `lb://ACCOUNTS` (Eureka name, chapter 9) became **`http://accounts:8080`** (Kubernetes Service DNS). Everything else in the route (path rewrite, circuit breaker, retry, rate limiter) is **identical**. Only the target changed.
- The `lb://` scheme is gone because there is no client-side load balancer to invoke; Kubernetes load balances behind that name.

Gateway `application.yml`:
```diff
-       discovery:
-         locator:
-           enabled: false
-           lowerCaseServiceId: true
+   kubernetes:
+     discovery:
+       enabled: true
+       all-namespaces: true
+   discovery:
+     client:
+       health-indicator:
+         enabled: false
```
- The Eureka-oriented `discovery.locator` block (chapter 9) is dropped. The Kubernetes discovery client is enabled (**`kubernetes.discovery.enabled: true`**, across all namespaces).
- **`discovery.client.health-indicator.enabled: false`**: turns off the discovery client's contribution to `/actuator/health`. The file doesn't say why; my reading is that it stops the gateway's health/readiness from depending on the discovery server being reachable (a dependency you'd rather not couple to readiness), but treat that as an educated guess.

### 3.4 The Spring Cloud Kubernetes Discovery Server: `kubernetes/kubernetes-discoveryserver.yml`
A single file with several objects (`kind: List`). Its job: give the app a **Spring-friendly registry API on top of the Kubernetes API**.
```yaml
1   apiVersion: v1
2   kind: List
3   items:
4     - apiVersion: v1
5       kind: Service
6       metadata:
7         labels: {app: spring-cloud-kubernetes-discoveryserver}
8         name: spring-cloud-kubernetes-discoveryserver
9       spec:
10        ports:
11          - name: http
12            port: 80
13            targetPort: 8761
14        selector: {app: spring-cloud-kubernetes-discoveryserver}
15        type: ClusterIP
16    - apiVersion: v1
17      kind: ServiceAccount
18      metadata: {name: spring-cloud-kubernetes-discoveryserver}
19    - apiVersion: rbac.authorization.k8s.io/v1
20      kind: RoleBinding
...
27    - apiVersion: rbac.authorization.k8s.io/v1
28      kind: Role
29      metadata:
30        namespace: default
31        name: namespace-reader
32      rules:
33        - apiGroups: ["", "extensions", "apps"]
34          resources: ["services", "endpoints", "pods"]
35          verbs: ["get", "list", "watch"]
36    - apiVersion: apps/v1
37      kind: Deployment
...
46          containers:
47          - name: spring-cloud-kubernetes-discoveryserver
48            image: springcloud/spring-cloud-kubernetes-discoveryserver:3.2.0
49            imagePullPolicy: IfNotPresent
50            readinessProbe:
51              httpGet: {port: 8761, path: /actuator/health/readiness}
52              initialDelaySeconds: 100
53              periodSeconds: 30
54            livenessProbe:
55              httpGet: {port: 8761, path: /actuator/health/liveness}
56              initialDelaySeconds: 100
57              periodSeconds: 30
58            ports:
59            - containerPort: 8761
```
- **Lines 4–15, the Service:** exposes the discovery server on port 80 → container 8761, `ClusterIP` (internal only). This is the address the Spring Cloud Kubernetes discovery client asks.
- **Lines 16–18, `ServiceAccount`:** an **identity for a Pod** inside the cluster, so the server can call the Kubernetes API as *itself*.
- **Lines 19–35, RBAC** (role-based access control): a **Role** named `namespace-reader` that may `get`, `list` and `watch` (lines 33–35) `services`, `endpoints` and `pods`, and a **RoleBinding** that gives that role to the ServiceAccount.
  Without this the discovery server would be forbidden from reading the cluster. **Note:** a Role is per-namespace (line 30 says `default`), so `all-namespaces: true` on the clients needs matching cluster-wide permissions in a real setup.
  Least-privilege: it can *read*, never modify.
- **Lines 46–49, the image:** the community-maintained `springcloud/spring-cloud-kubernetes-discoveryserver:3.2.0`.
- **Lines 50–57, probes:** here the manifests **do** declare readiness and liveness probes (contrast with chapter 15's manifests). `initialDelaySeconds: 100` gives the JVM 100 seconds before the first check, which is generous for a small Spring app (safer than a probe that kills a slow starter).

**Why does anyone need this server at all,** if calls use plain Service names? Because some features (the gateway's `DiscoveryClient`, `spring.cloud.kubernetes.discovery.*`, `/actuator` service lists, non-Spring clients) benefit from a list of instances and their metadata, without giving every app permission
to read the Kubernetes API. In the *actual routing* here, the URLs are static Service names, so the discovery server is optional plumbing the course adds to teach the option.

### 3.5 Helm charts updated: `eureka_enabled` becomes `discovery_enabled`
I compared `section_17/helm-new` with chapter 16's charts:
- The **`eurekaserver` chart is gone** (`eazybank-services/` now has accounts, cards, configserver, gatewayserver, loans, message).
- `eazybank-common/templates/deployment.yaml` replaces the Eureka block with a discovery block:
```yaml
43  {{- if .Values.discovery_enabled }}
44  - name: SPRING.CLOUD.KUBERNETES.DISCOVERY.DISCOVERY-SERVER-URL
45    valueFrom:
46      configMapKeyRef:
47        name: {{ .Values.global.configMapName }}
48        key: SPRING.CLOUD.KUBERNETES.DISCOVERY.DISCOVERY-SERVER-URL
49  {{- end }}
```
- **Line 44:** an environment variable that Spring's relaxed binding maps to `spring.cloud.kubernetes.discovery.discovery-server-url`: **the address of the discovery server** from 3.4. (Env var names containing dots are legal in Kubernetes, unusual but valid.)
- In the common `configmap.yaml` (line 9) this key is fed from `.Values.global.discoveryServerURL`, and the dev environment sets it to `http://spring-cloud-kubernetes-discoveryserver:80/`. That is exactly the **Service name and port 80** defined in 3.4's YAML (lines 8 and 12). This is how the two files connect.
- Only **`accounts` and `gatewayserver`** set `discovery_enabled: true` in their `values.yaml`. Those are the two services that call other services, so they are the ones that need a discovery client. Everything else stays as in chapter 16.
- **A leftover worth noticing:** `kube-prometheus/templates/configmap.yaml` (the monitoring chart) still has a scrape job `eurekaserver` targeting `eurekaserver.default.svc.cluster.local:8070`. Since Eureka no longer exists in this section, Prometheus will show that target permanently **down**. It's a
  harmless but classic "forgot to clean up the monitoring config" bug.

## 4. Try it (needs a cluster)
```bash
kubectl apply -f section_17/kubernetes/kubernetes-discoveryserver.yml
helm install eazybank section_17/helm-new/environments/dev-env      # after helm dependency build
kubectl get pods,svc
kubectl scale deployment loans-deployment --replicas=3
# call the gateway repeatedly; requests are spread over the 3 loans pods by the loans *Service*, not by any Java code:
kubectl logs -l app=loans --prefix --tail=5
```
Experiment: `kubectl delete pod` one loans pod during a load test and watch the Service stop routing to it almost immediately, with no Eureka delay.

## 5. Traps and senior notes
- **Hard-coded URLs are an environment assumption.** `http://loans:8090` only works if a Service named `loans` exists in the same namespace (or use `loans.<namespace>.svc.cluster.local`). Read them from config to keep the code portable.
- **Server-side load balancing is per *connection*, not per *request*.** kube-proxy balances when a TCP connection opens. Long-lived HTTP/2 or keep-alive connections can pin all traffic to one Pod. Service meshes (course section 19) and gRPC-aware LBs solve that.
- **Client-side discovery still has a niche:** running the same code on VMs, on-prem, or across clusters where there's no platform-level discovery.
- **Removing Eureka simplified operations** (one fewer service to secure, monitor and scale) at the cost of Kubernetes lock-in. That's the essential trade-off to be able to explain in an interview.
