# Walkthrough: start here

This walkthrough explains the EazyBank project **section by section, from scratch, with the real code walked through
line by line**. It is written the way a senior engineer would explain it to a new joiner: first *why*, then *what*,
then *how the code does it*.

## How each chapter is laid out
1. **The problem**: what was hurting before this section.
2. **The idea**: the concept, in plain words, with an analogy.
3. **Code walkthrough**: real files from this repo, with **numbered lines**.
4. **Try it / break it**: something you can run and observe.
5. **Traps and senior notes**: things that bite people in real projects.

## About the line numbers
The numbers in code blocks are **line numbers inside the excerpt**, not the original file. Where an excerpt shows `...` for skipped lines, the numbering jumps to keep the gap visible. To keep the code readable I removed
`import` lines, blank lines, Swagger annotations and comments. The file path is always printed above the excerpt, so you can open
the real file and find the same lines. When I say "line 7", I mean line 7 of the excerpt right above.

## Chapter list (read in order)
| # | Chapter | Core idea |
|---|---------|-----------|
| 02 | [Spring Boot services](02-section2-spring-boot-services.md) | The layered REST microservice |
| 04 | [Docker](04-section4-docker.md) | Package once, run anywhere |
| 06 | [Configuration management](06-section6-configuration.md) | Profiles, Config Server, refresh |
| 07 | [MySQL databases](07-section7-mysql.md) | A real database per service |
| 08 | [Service discovery](08-section8-service-discovery.md) | Eureka and Feign |
| 09 | [Gateway](09-section9-gateway.md) | One front door, routing, filters |
| 10 | [Resilience](10-section10-resilience.md) | Circuit breaker, retry, rate limiter, fallback |
| 11 | [Observability](11-section11-observability.md) | Logs, metrics, traces |
| 12 | [Security](12-section12-security.md) | OAuth2, JWT, Keycloak |
| 13–14 | [Events](13-14-section13-14-events.md) | Async messaging with RabbitMQ then Kafka |
| 15 | [Kubernetes](15-section15-kubernetes.md) | Orchestration |
| 16 | [Helm](16-section16-helm.md) | Templating Kubernetes YAML |
| 17 | [Kubernetes-native discovery](17-section17-k8s-discovery.md) | Let the platform do discovery |
| 20 | [BOM and common library](20-section20-bom.md) | Share code and versions safely |

Sections 1, 3, 5, 18 and 19 are theory or cloud demos with no code in this repo, so they are summarised in the chapters
where they matter.

## Vocabulary you will see everywhere

| Term | Plain meaning |
|------|---------------|
| **Bean** | An object that Spring creates and manages for you |
| **Dependency injection (DI)** | You don't call `new`; Spring hands you the objects a class needs (via the constructor) |
| **Annotation** (`@Service`, `@Bean`) | A label on code that tells Spring what to do with it |
| **Starter** (`spring-boot-starter-*`) | A Maven dependency that pulls in a whole feature with sane defaults |
| **Actuator** | Built-in `/actuator/*` endpoints (health, metrics, …) |
| **Profile** | A named set of config (`qa`, `prod`) you switch on at startup |
| **DTO** | Data Transfer Object: the shape of data on the wire, separate from your DB entity |
| **Idempotent** | Calling it twice has the same effect as once (GET, PUT, DELETE), which makes it safe to retry |
| **Reactive / WebFlux** | Non-blocking style used by the gateway (`Mono` = "a value that will arrive later") |

## The three things to remember about Spring Boot
1. **Convention over configuration.** Add a starter, and Boot auto-configures it. Config files only override defaults.
2. **`application.yml` is the control panel.** Almost every behaviour in this course is switched on there.
3. **Environment variables override files.** `SPRING_DATASOURCE_URL` overrides `spring.datasource.url`. Docker and Kubernetes rely on this
   (it's called *relaxed binding*).

## The example data used in every chapter
Every walkthrough uses one customer: mobile number `4354437687`, name `Madan Reddy`. When you see this number, it's the
same person moving through accounts, loans and cards.
