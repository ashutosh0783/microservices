# EazyBank Microservices – Project Documentation

This repo is the companion code for the course *Master Microservices with Spring Boot, Docker, Kubernetes*.
It builds **one application (EazyBank)** over and over, and each `sectionN` folder is a **snapshot of the
same project at a later stage of evolution**. So you read the sections in order, and each one adds one new concept.

| Doc | What it covers |
|-----|----------------|
| [01-architecture.md](01-architecture.md) | Final architecture, every component, and how a request flows through it |
| [02-sections-guide.md](02-sections-guide.md) | Section-by-section walkthrough: what each folder adds and which files to read |
| [03-services-reference.md](03-services-reference.md) | Ports, REST endpoints, config, messaging topics, security roles per service |
| [04-running-with-docker.md](04-running-with-docker.md) | How to run the full stack in Docker Desktop, URLs, sample calls, troubleshooting |
| [walkthrough/](walkthrough/00-start-here.md) | **Teaching walkthrough:** every section explained from scratch with the code walked through line by line |

## The 30-second version

EazyBank is a toy bank split into three business services plus the platform services that make them work as a system:

```
Client ──► Gateway Server (8072, OAuth2 / Keycloak) ──► Accounts (8080) ──► Loans (8090)
                │  routes via Eureka                            │  └──────► Cards (9000)
                │                                               └─ Kafka ──► Message (9010)
                └─ Config Server (8071) supplies config to everything; Eureka (8070) is the service registry
```

Observability (Grafana, Prometheus, Loki, Tempo) watches all of it.

## Repo layout

| Folder | Topic (course section) |
|--------|------------------------|
| `section2` | Plain Spring Boot REST microservices (accounts, loans, cards) |
| `section4` | Dockerfiles, Buildpacks, Jib: containerising each service |
| `section6` | Configuration management: `v1-springboot` (profiles, `@ConfigurationProperties`) → `v2-spring-cloud-config` (Config Server, Spring Cloud Bus, first Docker Compose with profiles) |
| `section7` | MySQL: a real database per service (three MySQL containers) |
| `section8` | Service discovery: Eureka server, Feign clients, load balancing |
| `section9` | Edge server: Spring Cloud Gateway, routing, correlation-id filters |
| `section_10` | Resilience4j: circuit breaker, retry, rate limiter, time limiter (plus Redis) |
| `section_11` | Observability: Grafana + Loki + Alloy + Prometheus + Tempo + OpenTelemetry |
| `section_12` | Security: OAuth2/OIDC with Keycloak, JWT validation at the gateway |
| `section_13` | Event-driven with RabbitMQ, Spring Cloud Function and Stream (`message` service) |
| `section_14` | Same, but with **Kafka**. **This is the most complete Docker Compose stack.** |
| `section_15` | Kubernetes manifests (`kubernetes/*.yml`) |
| `section_16` | Helm charts (`helm` = classic, `helm-new` = common-library-chart approach) |
| `section_17` | Kubernetes-native service discovery and load balancing (drops Eureka in favour of k8s Services) |
| `section_20` | Final code plus `eazy-bom` (shared Maven BOM/common library) |

There are no sections 3, 5, 18 and 19 in the repo. They are theory sections (right-sizing services, 12/15-factor apps)
or cloud and service-mesh demos with no code.

Other files in the root: `Microservices.postman_collection.json` (ready-made API calls for every stage) and the
course `README.md` (Docker / Maven / kubectl command cheat sheets).
