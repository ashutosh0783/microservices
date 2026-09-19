# 01 – Architecture

The description below is of the most complete Docker Compose version, `section_14`.

## Component map

```
                         ┌──────────────────────────── Observability ────────────────────────────┐
                         │ Alloy ─► Loki (logs)   Prometheus (metrics)   Tempo (traces) ─► Grafana │
                         └────────────────────────────────────────────────────────────────────────┘
                                   ▲ container logs      ▲ /actuator/prometheus   ▲ OTLP :4318
                                   │                     │                        │ (OpenTelemetry Java agent in every service)
 Client ──JWT──► GATEWAY SERVER :8072 ──lb://──► ACCOUNTS :8080 ──Feign──► LOANS :8090
   │              (Spring Cloud Gateway)              │        └──Feign──► CARDS :9000
   │                     │                            │
   │   validates JWT     │ looks up instances         │ StreamBridge          ┌─► MESSAGE :9010
   ▼   against JWKS      ▼                            ▼                       │   (email | sms functions)
 KEYCLOAK :7080       EUREKA :8070              KAFKA :9092 ─ send-communication ┘
                          ▲                            ▲──── communication-sent ◄─┘
                          │ register                   │ (Accounts consumes it and marks the account as "communication sent")
        all services ─────┴── CONFIG SERVER :8071 ──► Git repo (github.com/eazybytes/eazybytes-config)
```

## Business services

| Service | Responsibility | Data |
|---------|----------------|------|
| **accounts** | Customers and their savings account; also the *aggregator* (`fetchCustomerDetails` calls Loans and Cards) | H2 in-memory (`jdbc:h2:mem:testdb`) |
| **loans** | Loan per mobile number | H2 in-memory |
| **cards** | Credit card per mobile number | H2 in-memory |
| **message** | Stateless. Consumes "send-communication" events and simulates email and SMS | none |

Each business service has the same layered structure: `controller → service → repository → entity`, with `dto`,
`mapper` (entity to DTO), `exception` (`GlobalExceptionHandler`), `audit` (`createdAt/By`, `updatedAt/By` via `BaseEntity`).
Because the databases are in-memory, **data is lost whenever a container restarts**. Section 7 shows the MySQL variant.

## Platform services

| Component | Role | Key concept |
|-----------|------|-------------|
| **Config Server** (8071) | Central, environment-specific config (`accounts.yml`, `accounts-qa.yml`, `accounts-prod.yml`, …) served over HTTP. Config can be refreshed at runtime with `/actuator/refresh`. Secrets can be stored encrypted (`/encrypt`, `/decrypt`). | Externalised config (12-factor) |
| **Eureka Server** (8070) | Service registry. Each service registers its name and IP. Callers use the *logical name* (`lb://ACCOUNTS`), not a hard-coded host. | Client-side discovery and load balancing |
| **Gateway Server** (8072) | Single entry point. Routes `/eazybank/<svc>/**` to the right service, adds a `eazybank-correlation-id` header, enforces JWT security, applies per-route resilience (see below). | Edge server / API gateway |
| **Keycloak** (7080) | OAuth2 / OpenID Connect authorization server. Issues JWTs; roles `ACCOUNTS`, `CARDS`, `LOANS` are carried in the token. | AuthN/AuthZ |
| **Kafka** (9092) | Message broker for asynchronous Accounts ⇄ Message communication. | Event-driven architecture |

## Cross-cutting concerns and where they live

| Concern | Implementation |
|---------|----------------|
| **Routing** | `GatewayserverApplication.eazyBankRouteConfig()`. Each route rewrites `/eazybank/accounts/x` to `/x` and forwards to `lb://ACCOUNTS`. |
| **Security** | `gatewayserver/.../config/SecurityConfig.java`: all `GET`s are open. `/eazybank/accounts/**` needs role `ACCOUNTS`, cards needs `CARDS`, loans needs `LOANS`. `KeycloakRoleConverter` maps `realm_access.roles` into Spring authorities. |
| **Correlation id** | `RequestTraceFilter` (order 1) creates/propagates `eazybank-correlation-id`; `ResponseTraceFilter` echoes it back. Accounts forwards it via Feign so one request can be followed across services. |
| **Circuit breaker** | Accounts route uses `circuitBreaker(accountsCircuitBreaker)` with fallback `forward:/contactSupport` (`FallbackController`). Accounts to Loans/Cards Feign calls have `LoansFallback` / `CardsFallback`. |
| **Retry** | Loans route retries `GET` up to 3× with exponential back-off. `accounts /build-info` also uses `@Retry`. |
| **Rate limiting** | Cards route uses `RedisRateLimiter(1,1,1)`, keyed by the `user` header. It needs Redis, which **is not in the section 14 compose file** (see [04-running-with-docker.md](04-running-with-docker.md#known-caveats)). `accounts /java-version` uses Resilience4j `@RateLimiter`. |
| **Logging** | Log pattern `%5p [app,trace_id,span_id]`, container stdout collected by **Alloy**, stored in **Loki** (backed by MinIO). |
| **Metrics** | Micrometer to `/actuator/prometheus`, scraped by **Prometheus** every 5 s (targets in `observability/prometheus/prometheus.yml`). |
| **Tracing** | OpenTelemetry Java agent (`-javaagent:/app/libs/opentelemetry-javaagent-2.22.0.jar`) exports OTLP to **Tempo** `:4318`. **Grafana** links traces, logs and metrics. |
| **Health / readiness** | `/actuator/health/readiness` and `/liveness` are used by Docker healthchecks (and by Kubernetes probes in sections 15+). |
| **Validation and errors** | `jakarta.validation` on DTOs (name 5–30 chars, valid email, 10-digit mobile) and a `GlobalExceptionHandler` that returns `ErrorResponseDto`. |

## Request flow examples

### 1. Create an account (write path: JWT + async event)
1. Client obtains a token from Keycloak (client-credentials grant) and calls
   `POST :8072/eazybank/accounts/api/create` with `Authorization: Bearer …`.
2. Gateway validates the JWT (JWKS from Keycloak), checks role `ACCOUNTS`, adds the correlation id, and resolves
   `lb://ACCOUNTS` through Eureka.
3. Accounts saves `Customer` + `Accounts` in H2, then `StreamBridge.send("sendCommunication-out-0", AccountsMsgDto)`
   publishes to Kafka topic **`send-communication`**.
4. Message service runs the composed function `email|sms` (Spring Cloud Function composition), logs
   "Sending email…" / "Sending sms…", and emits the account number to topic **`communication-sent`**.
5. Accounts' `updateCommunication` consumer receives it and flips the account's `communicationSw` flag.

### 2. Fetch aggregated customer details (read path: fan-out)
`GET :8072/eazybank/accounts/api/fetchCustomerDetails?mobileNumber=…` (GET is public)
1. Gateway → Accounts `CustomerController`.
2. `CustomersServiceImpl` reads the customer + account from H2, then calls **Loans** and **Cards** through
   Feign clients (`lb://` via Eureka), forwarding the correlation id.
3. If Loans or Cards is down, the Feign fallback returns `null` and the response simply omits that block, instead
   of failing (a resilience demo).

## Technology stack (section 14 `pom.xml`)

Java 21 · Spring Boot 4.0.0 · Spring Cloud 2025.1.0 · Spring Cloud Config / Netflix Eureka / OpenFeign / Gateway /
Stream (Kafka binder) · Resilience4j · Spring Data JPA + H2 · springdoc-openapi · Lombok · Micrometer + OpenTelemetry ·
Images built with **Jib** (`mvn compile jib:dockerBuild`), tagged `eazybytes/<service>:s14`.
