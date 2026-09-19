# 02 – Section-by-section guide

Read the sections in order. Each one is a full, runnable copy of the project at that stage, so
`diff -r section8 section9` shows exactly what one concept added. Git history follows the same order
(commit messages match the section titles).

Legend: **New** = what this section introduces · **Read** = files worth opening first · **Run** = how to try it.

---

## Section 2 – Building microservices with Spring Boot (`section2/`)
**New:** three independent REST services (`accounts`, `loans`, `cards`), each with layered architecture,
Spring Data JPA on H2, DTOs + mappers, bean validation, global exception handling, JPA auditing, OpenAPI docs.
**Read:** `accounts/.../controller/AccountsController.java` (CRUD on `/api/create|fetch|update|delete`),
`dto/CustomerDto.java` (validation rules), `exception/GlobalExceptionHandler.java`, `entity/BaseEntity.java`.
**Run:** `cd section2/accounts && mvn spring-boot:run` → http://localhost:8080/swagger-ui/index.html
(loans `:8090`, cards `:9000`). H2 console: `/h2-console`.

## Section 3 – Right-sizing microservices *(theory, no code)*
Domain-driven design, event storming and bounded contexts. This is why the bank is split into accounts, loans and cards.

## Section 4 – Docker (`section4/`)
**New:** getting each service into a container. The three approaches are a hand-written `Dockerfile`, Cloud Native
Buildpacks (`mvn spring-boot:build-image`) and Google Jib (`mvn compile jib:dockerBuild`).
**Read:** `accounts/Dockerfile`, the Jib plugin in `pom.xml`.
**Run:** `docker build . -t eazybytes/accounts:s4 && docker run -p 8080:8080 eazybytes/accounts:s4`

## Section 5 – Cloud-native / 15-factor apps *(theory)*
The principles behind the rest of the course (config in the environment, stateless processes, disposability, etc.).

## Section 6 – Configuration management (`section6/`)
**`v1-springboot`:** Spring profiles (`application_qa.yml`, `_prod.yml`), `@Value`, `Environment`, and
`@ConfigurationProperties` records (`AccountsContactInfoDto`), plus overriding config through env vars / command line.
**`v2-spring-cloud-config`:** adds the **`configserver`** service (reads a Git/classpath/file repo) and turns the
business services into config *clients* (`spring.config.import: optional:configserver:http://localhost:8071/`).
Also shows `/actuator/refresh` for live refresh, Spring Cloud Bus (RabbitMQ) refresh, and `/encrypt` for secrets. `v2` is also where **Docker Compose with `default`/`qa`/`prod` profile folders** and shared `common-config.yml` templates first appear.
**Read:** `configserver/src/main/resources/application.yml` and the `config/` folder (`accounts.yml`, `accounts-qa.yml`,
`accounts-prod.yml`); `docker-compose/`.

## Section 7 – MySQL databases (`section7/`)
**New:** a **real database per service**. `accounts`, `loans` and `cards` switch from in-memory H2 to three separate MySQL containers (`accountsdb`, `loansdb`, `cardsdb`, host ports 3306/3307/3308).
`application.yml` gets a `jdbc:mysql://…` URL and `sql.init.mode: always` so `schema.sql` runs on start-up; the `h2` dependency is replaced by `mysql-connector-j`. The Compose file adds
a `microservice-db-config` template with a `mysqladmin ping` health check, and each service `depends_on` its own DB being healthy.
**Read:** `accounts/src/main/resources/application.yml`, `schema.sql`, `docker-compose/default/common-config.yml`.
**Run:** `cd section7/docker-compose/default && docker compose up -d`
(Compose files with the `default`/`qa`/`prod` profile folders first appear in **section 6 v2**, next to the Config Server and a RabbitMQ container used by Spring Cloud Bus.)

## Section 8 – Service discovery & registration (`section8/`)
**New:** the **`eurekaserver`** and Feign clients (`CardsFeignClient`, `LoansFeignClient`) so Accounts calls other
services by logical name. `fetchCustomerDetails` on Accounts aggregates data from all three.
**Read:** `eurekaserver/.../EurekaserverApplication.java`, `accounts/.../service/client/*`, `CustomersServiceImpl`.
**Try:** http://localhost:8070 shows every registered instance. Scale one with
`docker compose up -d --scale loans=2` (remove `container_name` first) and watch client-side load balancing.

## Section 9 – Gateway & cross-cutting concerns (`section9/`)
**New:** **`gatewayserver`** (Spring Cloud Gateway). Route definitions, path rewriting, custom response headers, and
global filters (`RequestTraceFilter`, `ResponseTraceFilter`) that generate/propagate `eazybank-correlation-id`.
**Read:** `gatewayserver/.../GatewayserverApplication.java`, `filters/*`.
**Try:** `GET http://localhost:8072/eazybank/accounts/api/contact-info`.

## Section 10 – Resilience (`section_10/`)
**New:** Resilience4j patterns applied at two levels.
* Gateway: **circuit breaker** on the accounts route (fallback `/contactSupport`), **retry** on loans, **Redis rate
  limiter** on cards. This is why `docker-compose` gains a `redis` service.
* Service: `@Retry`, `@RateLimiter`, Feign circuit breaker with fallback classes (`LoansFallback`, `CardsFallback`).
Settings live under `resilience4j.*` in `application.yml`.
**Try:** stop `loans`, call `fetchCustomerDetails` → the response still returns 200, with `loansDto: null`.

## Section 11 – Observability & monitoring (`section_11/`)
**New:** the "three pillars", all in `docker-compose/observability/`:
* **Logs:** Alloy collects Docker container logs to Loki (read/write/backend + nginx gateway, MinIO as storage).
* **Metrics:** Micrometer to Prometheus (`prometheus.yml`).
* **Traces:** OpenTelemetry Java agent to Tempo.
* **Grafana** (`datasource.yml`) ties them together (logs to trace via `trace_id` in the log pattern).
**Try:** http://localhost:3000 (anonymous admin), *Explore* → Loki / Prometheus / Tempo.

## Section 12 – Security with OAuth2 & Keycloak (`section_12/`)
**New:** **Keycloak** container, and the gateway becomes an OAuth2 *resource server*
(`SecurityConfig`, `KeycloakRoleConverter`). Covers client-credentials flow (machine-to-machine) and
authorization-code flow (a user logs in). Postman folder `gatewayserver_security` has every call.
**Read:** `SecurityConfig.java` (GET open, mutating calls need roles) and `spring.security.oauth2.resourceserver.jwt.jwk-set-uri`.

## Section 13 – Event-driven with RabbitMQ (`section_13/`)
**New:** the **`message`** service and asynchronous communication using **Spring Cloud Function + Spring Cloud Stream**.
Accounts publishes via `StreamBridge`, Message processes `email|sms`, Accounts consumes the acknowledgement
(`AccountsFunctions.updateCommunication`). Broker: RabbitMQ (`rabbitmq:4.0-management`, UI on `:15672`).

## Section 14 – Event-driven with Kafka (`section_14/`) ← *what we run*
Same topology as 13 with the binder swapped to **Kafka** (`apache/kafka:4.1.1`, KRaft mode — no ZooKeeper).
Only configuration changes: the Kafka binder dependency and `spring.cloud.stream.kafka.binder.brokers`.
Business code is identical, which is the point of the Stream abstraction.
Topics: `send-communication` (Accounts → Message), `communication-sent` (Message → Accounts).

## Section 15 – Kubernetes (`section_15/kubernetes/`)
**New:** the same stack as plain manifests, numbered in apply order: `1_keycloak.yml`, `2_configmaps.yaml`,
`3_configserver.yml`, `4_eurekaserver.yml`, `5_accounts.yml`, `6_loans.yml`, `7_cards.yml`, `8_gateway.yml`.
Each has a `Deployment` + `Service`; ConfigMaps replace `.env`/compose `environment`.
**Run:** enable Kubernetes in Docker Desktop, then `kubectl apply -f section_15/kubernetes/`.

## Section 16 – Helm (`section_16/`)
**New:** packaging the manifests as charts with templating and values. Two generations live side by side:
* `helm/` – first version: `eazybank-common` (shared templates), `eazybank-services/*` (one chart per microservice),
  `environments/*` (umbrella charts per environment) plus infrastructure charts (`keycloak`, `kafka`, `grafana`,
  `grafana-loki`, `grafana-tempo`, `kube-prometheus`).
* `helm-new/` – refreshed version of the same layout: adds `grafana-alloy` and has `environments/{dev,qa,prod}-env`.
Each service chart depends on `eazybank-common`, so `eazybank-services/accounts` is tiny (`values.yaml` + thin templates).
**Run:** `helm dependency build environments/dev-env && helm install eazybank environments/dev-env`

## Section 17 – Kubernetes-native discovery (`section_17/`)
**New:** the `eurekaserver` is **removed**. Accounts' Feign clients now use plain Kubernetes Service DNS
(`@FeignClient(name="cards", url="http://cards:9000")`), so load balancing is server-side (kube-proxy).
The gateway and services use the `spring-cloud-starter-kubernetes-discoveryclient`; `kubernetes/kubernetes-discoveryserver.yml`
deploys the Spring Cloud Kubernetes discovery server. `helm/` and `helm-new/` are updated to match.

## Sections 18 & 19 *(no code in repo)*
Deploying to a cloud cluster (GKE) and Ingress / Istio service mesh / mTLS demos.

## Section 20 – Final code (`section_20/`)
Final consolidated version and **`eazy-bom`**, a parent BOM plus a `common` library
(`ErrorResponseDto`) that de-duplicates code shared by the services.

---

### Suggested learning path
1. Run section 2 by itself; hit Swagger UI.
2. Diff 2 → 4 → 6 → 7 to see config and containers layered on.
3. Bring up section 14 (see [04](04-running-with-docker.md)) and watch the concepts of 8–14 working together in Docker Desktop.
4. Read the Kubernetes and Helm sections last. They re-package what you already understand.
