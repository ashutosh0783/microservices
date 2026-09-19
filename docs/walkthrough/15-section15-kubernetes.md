# Chapter 15: Container orchestration with Kubernetes (`section_15/kubernetes/`)

> **Verification note:** this chapter is a code walkthrough. This machine has `kubectl` but **no Kubernetes cluster enabled** in Docker Desktop, so I did not apply these manifests. Everything below is read straight from the files. Enable
> *Settings → Kubernetes* in Docker Desktop if you want to run them.

## 1. The problem
Docker Compose runs containers on **one machine**. Production needs:
- **Many machines**: if one dies, workloads move to another.
- **Self-healing**: a crashed container is restarted automatically.
- **Scaling**: "run 5 copies of loans", up or down on demand.
- **Zero-downtime updates**: replace v1 with v2 gradually, and roll back if it goes wrong.
- **Built-in service discovery and load balancing.**

That is what **Kubernetes (K8s)** does: you *declare* the desired state ("3 copies of this container, reachable at this name") and Kubernetes continuously works to make reality match.

## 2. The idea: declare desired state; a control loop reconciles

```
you write YAML ──kubectl apply──► API server stores "desired state"
                                        │
   controllers watch: "desired = 3 pods, actual = 2"  ──► start one more pod   (repeat forever)
```

**The objects used in this section:**

| Object | What it is | Analogy |
|--------|------------|---------|
| **Pod** | 1+ containers scheduled together; the smallest unit. Has its own IP, which changes when it's replaced | One running dish |
| **Deployment** | "Keep N identical Pods running; roll out updates" | The manager who keeps N cooks on shift |
| **ReplicaSet** | Created by a Deployment to hold the N pods (you rarely touch it) | The shift roster |
| **Service** | A **stable name and virtual IP** in front of a changing set of Pods, with load balancing | The restaurant's phone number, whichever cook picks up |
| **ConfigMap** | Key/value configuration injected into Pods | The pinned notice board |
| **Labels & selectors** | Tags on objects, and queries that find objects by tag | How a Service knows which Pods are "its" pods |

## 3. Code walkthrough

There are 8 numbered files, applied in order because later ones depend on earlier ones (`kubectl apply -f section_15/kubernetes/`). The numbers exist because **the ConfigMap must exist before Pods that reference it**.

### 3.1 The shared configuration: `2_configmaps.yaml`
```yaml
1  apiVersion: v1
2  kind: ConfigMap
3  metadata:
4    name: eazybank-configmap
5  data:
6    SPRING_PROFILES_ACTIVE: "prod"
7    SPRING_CONFIG_IMPORT: "configserver:http://configserver:8071/"
8    EUREKA_CLIENT_SERVICEURL_DEFAULTZONE: "http://eurekaserver:8070/eureka/"
9    CONFIGSERVER_APPLICATION_NAME: "configserver"
10   EUREKA_APPLICATION_NAME: "eurekaserver"
11   ACCOUNTS_APPLICATION_NAME: "accounts"
12   LOANS_APPLICATION_NAME: "loans"
13   CARDS_APPLICATION_NAME: "cards"
14   GATEWAY_APPLICATION_NAME: "gatewayserver"
15   KC_BOOTSTRAP_ADMIN_USERNAME: "admin"
16   KC_BOOTSTRAP_ADMIN_PASSWORD: "admin"
17   SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK-SET-URI: "http://keycloak:7080/realms/master/protocol/openid-connect/certs"
```
- **Lines 1–2**: every K8s object starts with `apiVersion` + `kind`. **Lines 3–4**: its name (other files refer to it by this name).
- **Lines 6–8**: the exact same environment variables chapter 7 put in `common-config.yml`, but now in one cluster-wide object. **This is the 12-factor idea again**: same image, config supplied from outside.
- **Line 7**: `http://configserver:8071/` uses the **Kubernetes Service name** `configserver` as the host (Services get DNS names automatically, like container names on the Docker network).
- **Lines 9–14**: one application name per service.
- **Lines 15–16 and 17**: Keycloak credentials (in a ConfigMap, i.e. **plain text**) and the JWKS URL for the gateway. **Trap:** passwords belong in a **Secret** (still only base64, but access-controlled), or better an external secret manager. This is demo-grade.

### 3.2 A service: `5_accounts.yml` (loans, cards, configserver, eurekaserver follow the same pattern)
```yaml
1  apiVersion: apps/v1
2  kind: Deployment
3  metadata:
4    name: accounts-deployment
5    labels:
6      app: accounts
7  spec:
8    replicas: 1
9    selector:
10     matchLabels:
11       app: accounts
12   template:
13     metadata:
14       labels:
15         app: accounts
16     spec:
17       containers:
18       - name: accounts
19         image: eazybytes/accounts:s12
20         ports:
21         - containerPort: 8080
22         env:
23         - name: SPRING_APPLICATION_NAME
24           valueFrom:
25             configMapKeyRef:
26               name: eazybank-configmap
27               key: ACCOUNTS_APPLICATION_NAME
28         - name: SPRING_PROFILES_ACTIVE
29           valueFrom:
30             configMapKeyRef:
31               name: eazybank-configmap
32               key: SPRING_PROFILES_ACTIVE
33         - name: SPRING_CONFIG_IMPORT
...
38         - name: EUREKA_CLIENT_SERVICEURL_DEFAULTZONE
...
43 ---
44 apiVersion: v1
45 kind: Service
46 metadata:
47   name: accounts
48 spec:
49   selector:
50     app: accounts
51   type: LoadBalancer
52   ports:
53     - protocol: TCP
54       port: 8080
55       targetPort: 8080
```
**The Deployment (lines 1–42):**
- **Line 8, `replicas: 1`**: desired number of Pods. Change to 3 and apply: Kubernetes starts two more. That's horizontal scaling in one line.
- **Lines 9–11, `selector.matchLabels`** and **lines 13–15, `template.metadata.labels`**: the Deployment finds *its* Pods by the label `app: accounts`. **These two must match** or the Deployment can't own its Pods (`kubectl apply` rejects mismatches).
- **Lines 12–21, `template`**: the **Pod blueprint**. **Line 19, `image: eazybytes/accounts:s12`**: note the tag is **`s12`**. The section-15 manifests deploy the *section-12* images (security, no Kafka), so the `message` service and Kafka aren't part of this section.
  **Line 21** is documentation for humans; `containerPort` doesn't publish anything.
- **Lines 22–42, `env`**: each variable's value comes from the ConfigMap via `configMapKeyRef` (name of the ConfigMap + key). Compare with Compose's `environment:`. The Java app reads them exactly as before.
  Spring's relaxed binding turns `SPRING_CONFIG_IMPORT` into `spring.config.import`.

**The Service (lines 43–55):**
- **Line 47, `name: accounts`**: this becomes the **DNS name** `accounts` inside the cluster (the same name Feign or the gateway uses).
- **Lines 49–50, `selector: app: accounts`**: route traffic to any Pod carrying that label. When Pods die and are replaced with new IPs, the Service **automatically follows**: this fixes the "IPs change constantly" problem that Eureka solved in chapter 8.
- **Line 51, `type: LoadBalancer`**: expose it outside the cluster. On Docker Desktop's Kubernetes that maps to `localhost:8080`; on a cloud provider it creates a real cloud load balancer (with cost). The other types are `ClusterIP` (internal only, the default) and `NodePort`.
- **Lines 54–55**: `port` is what the Service listens on; `targetPort` is the container's port. They're the same here.

### 3.3 Keycloak: `1_keycloak.yml`
```yaml
18   - name: keycloak
19     image: quay.io/keycloak/keycloak:26.4.7
20     args: ["start-dev"]
21     env:
22       - name: KC_BOOTSTRAP_ADMIN_USERNAME
23         valueFrom: {configMapKeyRef: {name: eazybank-configmap, key: KC_BOOTSTRAP_ADMIN_USERNAME}}
...
32     ports:
33       - name: http
34         containerPort: 8080
...
45   type: LoadBalancer
46   ports:
47     - name: http
48       port: 7080
49       targetPort: 8080
```
- **Line 20, `args`** passes `start-dev` to the container's entrypoint (the equivalent of Compose's `command:`).
- **Lines 47–49**: the Service listens on **7080** and forwards to the container's 8080. That's why the ConfigMap's JWKS URL says `keycloak:7080`. Same trick as the `7080:8080` mapping in Compose.

### 3.4 The gateway: `8_gateway.yml`
Same shape as accounts, with `image: eazybytes/gatewayserver:s12`, port **8072**, and one extra environment variable, the JWKS URL (lines 43–47), taken from the ConfigMap. Its Service is `type: LoadBalancer` on 8072: **the only thing you really need exposed to the outside**. The other Services could be `ClusterIP`; the course leaves them as LoadBalancer for easy poking during learning.

## 4. Try it (needs Kubernetes enabled in Docker Desktop)
```bash
kubectl config use-context docker-desktop
kubectl apply -f section_15/kubernetes/
kubectl get pods                     # STATUS goes ContainerCreating → Running
kubectl get services                 # EXTERNAL-IP localhost for LoadBalancers
kubectl logs deployment/accounts-deployment
kubectl scale deployment accounts-deployment --replicas=3
kubectl delete pod <one-accounts-pod>   # watch it be recreated instantly (self-healing)
kubectl describe pod <pod>              # events explain why a pod is Pending/CrashLoopBackOff
```
Useful states: `Pending` (can't be scheduled yet), `ImagePullBackOff` (image name/tag wrong), `CrashLoopBackOff` (app starts then dies; read `kubectl logs --previous`).

## 5. Traps and senior notes
- **Startup ordering doesn't exist here.** Compose had `depends_on: service_healthy`. Kubernetes starts everything at once, so `accounts` may boot before the config server is ready. Spring Boot's retry behaviour, **readiness probes** and init containers are how you cope.
  The `/actuator/health/readiness` and `/liveness` endpoints these apps expose (chapter 6/7 config) exist precisely for K8s **probes**: liveness = "restart me if false", readiness = "don't send me traffic yet". These manifests don't declare probes; a real deployment would.
- **No resource requests/limits** are declared, so one pod can starve others. Production manifests always set them (Compose's `memory: 700m` was the equivalent).
- **Don't hand-copy YAML for 8 services.** Note how 5, 6, 7, 3, 4 are nearly identical. That duplication is the problem Helm solves in chapter 16.
- **Pods are cattle, not pets.** Never `exec` in and hand-edit; change the manifest and re-apply.
