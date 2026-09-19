# 03 – Services reference (section 14)

## Ports at a glance

| Component | Container | Host URL | Notes |
|-----------|-----------|----------|-------|
| Gateway Server | `gatewayserver-ms` | http://localhost:8072 | **Use this as your API entry point** |
| Accounts | `accounts-ms` | *(internal 8080, not published)* | reach it through the gateway |
| Loans | `loans-ms` | *(internal 8090, not published)* | reach it through the gateway |
| Cards | `cards-ms` | *(internal 9000, not published)* | reach it through the gateway |
| Message | `message-ms` | *(internal 9010, not published)* | Kafka-driven, no public API |
| Config Server | `configserver-ms` | http://localhost:8071 | e.g. `/accounts/default`, `/actuator/health` |
| Eureka Server | `eurekaserver-ms` | http://localhost:8070 | Registry dashboard |
| Keycloak | `keycloak` | http://localhost:7080 | `admin` / `admin` (bound to 127.0.0.1 only) |
| Kafka | `kafka` | `localhost:9092` | KRaft, single broker |
| Grafana | `eazybank-grafana-1` | http://localhost:3000 | Anonymous admin, no login |
| Prometheus | `prometheus` | http://localhost:9090 | Targets page shows scrape status |
| Tempo | `tempo` | http://localhost:3110 (API), `:4318` (OTLP) | Queried from Grafana |
| Loki gateway (nginx) | `eazybank-gateway-1` | http://localhost:3100 | `/ready`, push/query API |
| Loki read / write | `eazybank-read-1` / `-write-1` | `:3101` / `:3102` | |
| Alloy | `eazybank-alloy-1` | http://localhost:12345 | Log collector UI |
| MinIO | `eazybank-minio-1` | random host port → 9000 | Loki object storage (`loki` / `supersecret`) |

Only Config, Eureka and the Gateway publish ports to the host (see `docker-compose/default/docker-compose.yml`).
The business services can only be reached from inside the `eazybank` Docker network; this is intentional and is
what an edge server is for.

## Business service REST API

Identical shape for accounts, loans and cards, all under `/api`. Through the gateway the prefix is
`/eazybank/<service>` (e.g. `http://localhost:8072/eazybank/loans/api/fetch?mobileNumber=…`).

### Accounts (`/eazybank/accounts/api/...`)
| Method | Path | Purpose | Body / params |
|--------|------|---------|---------------|
| POST | `/create` | Create customer + savings account, then fires a Kafka event | JSON `{ "name": "Madan Reddy", "email": "tutor@eazybytes.com", "mobileNumber": "4354437687" }` |
| GET | `/fetch` | Customer + account | `?mobileNumber=` |
| PUT | `/update` | Update customer/account (the account number identifies the account) | JSON `CustomerDto` with nested `accountsDto` |
| DELETE | `/delete` | Delete customer + account | `?mobileNumber=` |
| GET | `/fetchCustomerDetails` | **Aggregate**: customer + account + loan + card | `?mobileNumber=` and header `eazybank-correlation-id` (the gateway adds it) |
| GET | `/build-info` | Config-driven build version (demonstrates `@Retry`) | – |
| GET | `/java-version` | JVM version from the environment (demonstrates `@RateLimiter`, 1 call / 5 s) | – |
| GET | `/contact-info` | `@ConfigurationProperties` values from the Config Server | – |

Validation: `name` 5–30 chars, `email` valid, `mobileNumber` exactly 10 digits. The account number is 10 digits.

### Loans (`/eazybank/loans/api/...`)
`POST /create?mobileNumber=`, `GET /fetch?mobileNumber=`, `PUT /update` (body: `mobileNumber`, `loanNumber` (12 digits),
`loanType`, `totalLoan`, `amountPaid`, `outstandingAmount`), `DELETE /delete?mobileNumber=`, plus
`/build-info`, `/java-version`, `/contact-info`.

### Cards (`/eazybank/cards/api/...`)
`POST /create?mobileNumber=`, `GET /fetch?mobileNumber=`, `PUT /update` (body: `mobileNumber`, `cardNumber` (12 digits),
`cardType`, `totalLimit`, `amountUsed`, `availableAmount`), `DELETE /delete?mobileNumber=`, plus
`/build-info`, `/java-version`, `/contact-info`.

Interactive docs (springdoc) are at `/swagger-ui/index.html` on each service. They are only reachable from inside the
Docker network here. Use the Postman collection `Microservices.postman_collection.json` for the gateway paths.

## Gateway routes

| Incoming path | Target | Extra behaviour |
|---------------|--------|-----------------|
| `/eazybank/accounts/**` | `lb://ACCOUNTS` | circuit breaker `accountsCircuitBreaker`, fallback `/contactSupport`, header `X-Response-Time` |
| `/eazybank/loans/**` | `lb://LOANS` | retry GET ×3, exponential back-off 100 ms → 1 s |
| `/eazybank/cards/**` | `lb://CARDS` | Redis rate limiter (1 req/s), keyed by header `user` |

Security matrix: `GET` on anything → **public**. Non-GET on `/eazybank/accounts/**` → role `ACCOUNTS`,
`/eazybank/cards/**` → `CARDS`, `/eazybank/loans/**` → `LOANS`. Actuator endpoints of the gateway are exposed as well
(`/actuator/gateway/routes` lists the active routes).

## Messaging (Kafka via Spring Cloud Stream)

| Topic | Producer | Consumer | Payload |
|-------|----------|----------|---------|
| `send-communication` | Accounts (`sendCommunication-out-0`, via `StreamBridge`) | Message (`emailsms-in-0`, function `email\|sms`) | `AccountsMsgDto(accountNumber, name, email, mobileNumber)` |
| `communication-sent` | Message (`emailsms-out-0`) | Accounts (`updateCommunication-in-0`, group `accounts`) | account number (`Long`) |

To see it working: create an account, then read `docker logs message-ms` (email + sms log lines) and
`docker logs accounts-ms` ("Updating Communication status for the account number …").

## Configuration

| Where | What |
|-------|------|
| `<service>/src/main/resources/application.yml` | Baked into each image: port, actuator, Eureka, Resilience4j, Stream bindings |
| Config Server → Git repo `https://github.com/eazybytes/eazybytes-config` (branch `main`) | Per-service, per-profile overrides (`accounts.yml`, `accounts-prod.yml`, …). The **course author's** repo, not yours |
| `docker-compose/default/common-config.yml` | Env vars injected into every container: `SPRING_CONFIG_IMPORT`, `EUREKA_CLIENT_SERVICEURL_DEFAULTZONE`, OTel agent settings, 700 MB memory limit |
| `section_14/configserver/src/main/resources/config/*.yml` | Local copy of the same config files (used if you switch the server to the `native` profile) |

Compose profile folders: `default/` (used here), `qa/`, `prod/` differ only in `SPRING_PROFILES_ACTIVE` (set in each `common-config.yml`),
which makes the Config Server return `accounts-qa.yml` / `accounts-prod.yml` overrides.

## Actuator endpoints (each service, exposure `*`)
`/actuator/health`, `/actuator/health/readiness`, `/actuator/info`, `/actuator/metrics`, `/actuator/prometheus`,
`/actuator/refresh` (POST), `/actuator/shutdown` (POST).
The gateway and config/eureka servers also expose theirs on `8072/8071/8070`.
