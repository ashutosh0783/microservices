# Chapter 6: Configuration management (`section6/`)

Two folders show two stages: `v1-springboot` (profiles inside the app) and `v2-spring-cloud-config` (a dedicated Config Server).

## 1. The problem
The same build must run in **dev, QA and prod**, and each environment needs different values (contact person, database URL, feature flags).
Rebuilding an image per environment is slow and risky: *the artifact you tested is no longer the artifact you ship.*

Principle (from the 12-factor / 15-factor methodology): **build once, configure at deploy time.**

## 2. The idea
Keep the image identical and **inject configuration from outside**. There are three levels, from simplest to most scalable:

1. **Profiles** in the app's own files (`v1`).
2. **Environment variables / command-line args** that override files.
3. A central **Config Server** that all services ask for their settings (`v2`).

Spring resolves all of these in a **priority order** (highest wins): command-line args → environment variables → profile-specific files → default
`application.yml`.

## 3. Code walkthrough

### 3.1 v1: profiles inside the app
`application.yml` (base):
```yaml
17   config:
18     import:
19       - "application_qa.yml"
20       - "application_prod.yml"
21   profiles:
22     active:
23       - "qa"
...
26 build:
27   version: "3.0"
29 accounts:
30   message: "Welcome to EazyBank accounts related local APIs "
31   contactDetails:
32     name: "John Doe - Developer"
33     email: "john@eazybank.com"
34   onCallSupport:
35     - (555) 555-1234
36     - (555) 523-1345
```
- **Lines 17–20, `spring.config.import`**: pull the two extra files in. (Boot doesn't auto-load these names, because they aren't the standard
  `application-{profile}.yml` pattern, so we import them explicitly.)
- **Lines 21–23, `profiles.active: qa`**: switch the `qa` profile on. Anything in a section tagged `qa` overrides the defaults.
- **Lines 26–36**: the default ("local") values. `build.version`, plus a nested `accounts` object: a message, contact details (a map) and a list of phone numbers.

`application_qa.yml`:
```yaml
1  spring:
2    config:
3      activate:
4        on-profile: "qa"
6  build:
7    version: "2.0"
9  accounts:
10   message: "Welcome to EazyBank accounts related QA APIs "
11   contactDetails:
12     name: "Smitha Ray - QA Lead"
```
- **Lines 3–4, `activate.on-profile: "qa"`**: "this file's values apply only when the `qa` profile is active".
  `application_prod.yml` is the same idea with `"prod"` and version `1.0`.
- Result: same jar, but with `qa` active `build-info` returns `2.0`, and with `prod` it returns `1.0`.

**Three ways to read configuration into code** (all in `AccountsController`):

```java
// 1) @Value: one property
45 @Value("${build.version}")
46 private String buildVersion;
// 2) Environment: look anything up by key at runtime
48 @Autowired
49 private Environment environment;      // environment.getProperty("JAVA_HOME")
// 3) @ConfigurationProperties: a whole group into a typed object
51 @Autowired
52 private AccountsContactInfoDto accountsContactInfoDto;
```
`AccountsContactInfoDto.java`:
```java
5  @ConfigurationProperties(prefix = "accounts")
6  public record AccountsContactInfoDto(String message, Map<String, String> contactDetails, List<String> onCallSupport) {
7  }
```
- **Line 5**: bind everything under the YAML key `accounts` into this object. **Line 6**: a Java `record` (an immutable data holder). Field names match YAML
  keys: `message`, `contactDetails` (→ `Map`), `onCallSupport` (→ `List`).
- It's activated by `@EnableConfigurationProperties(value = {AccountsContactInfoDto.class})` on `AccountsApplication` (line 19 of that file). Without that annotation
  the record is never created and injection fails.
- **When to use which:** `@Value` for one-off values, `@ConfigurationProperties` for groups (type-safe, validated, easy to test), and `Environment` only for dynamic lookups.

**Overriding from outside** (no rebuild):
```bash
java -jar accounts.jar --spring.profiles.active=prod              # command-line arg
SPRING_PROFILES_ACTIVE=prod java -jar accounts.jar                # environment variable
java -jar accounts.jar --build.version=9.9                        # override a single value
```

### 3.2 v2: a Config Server
With 3 services × 3 environments, editing files inside each jar is unmanageable. So we centralise.

**The server**, `ConfigserverApplication.java`:
```java
2  @SpringBootApplication
3  @EnableConfigServer
4  public class ConfigserverApplication {
5  	public static void main(String[] args) { SpringApplication.run(ConfigserverApplication.class, args); }
```
- **Line 3, `@EnableConfigServer`** turns this ordinary app into a server that serves config over HTTP: `GET /{application}/{profile}` (e.g. `/accounts/prod`).

**Its configuration** (`configserver/src/main/resources/application.yml`):
```yaml
1  spring:
2    application:
3      name: "configserver"
4    profiles:
5      # active: native
6      active: git
7    cloud:
8      config:
9        server:
10         git:
14           uri: "https://github.com/eazybytes/eazybytes-config.git"
15           default-label: main
16           timeout: 5
17           clone-on-start: true
18           force-pull: true
19   rabbitmq:
20     host: "localhost"
21     port: 5672
22     username: "guest"
23     password: "guest"
...
38 encrypt:
39   key: "45D81EC1EF61DF9AD8D3E5BB397F9"
40 server:
41   port: 8071
```
- **Lines 4–6**: the server has its own profiles for **where** config lives: `git` (a Git repo), `native` (local classpath/folder; lines 10–12 are
  the commented-out native settings). Using Git gives you **history, pull-request review and rollback of configuration**, which is a big win.
- **Line 14**: the repository. **This is the course author's repo**, not yours: change this URI to point at your own fork of the config repo.
- **Line 15**: branch. **Line 16**: fail fast after 5 s if Git is unreachable. **Line 17**: clone at startup so the first request is fast.
  **Line 18**: discard local changes and re-pull, so the server never drifts from Git.
- **Lines 19–23**: a RabbitMQ connection. It's used by **Spring Cloud Bus** (3.4) to broadcast "config changed" to all services.
- **Line 39, `encrypt.key`**: a symmetric key for the `/encrypt` and `/decrypt` endpoints, so passwords can be stored in Git as `{cipher}…`. **Trap:** a
  key committed in a public repo (like here) is **not secret**, so this is only OK for a demo. In production the key comes from a secret store.
- **Line 41**: port 8071.
- The `config/` folder (`accounts.yml`, `accounts-qa.yml`, `accounts-prod.yml`, and the same for loans and cards) is the classpath version used by the `native` profile.
  The file naming rule is `{application}-{profile}.yml`: `accounts-prod.yml` applies to application `accounts` with profile `prod`.

**The client side** (`accounts/src/main/resources/application.yml`):
```yaml
3  spring:
4    application:
5      name: "accounts"
6    profiles:
7      active: "prod"
...
17   config:
18     import: "optional:configserver:http://localhost:8071/"
```
- **Line 5**: the application **name is the lookup key**: this service asks the Config Server for `accounts`.
- **Line 7**: which profile. **Line 18, `spring.config.import`**: "at startup, fetch config from `http://localhost:8071/`". `optional:` means **don't crash if the server isn't there**;
  use defaults instead, handy when running a service alone on your laptop. In Docker the env var `SPRING_CONFIG_IMPORT: configserver:http://configserver:8071/` (no `optional:`) overrides
  it, so a missing server **does** fail startup, which is what you want in production.
- The pom adds `spring-cloud-starter-config` (the client) and `spring-cloud-starter-bus-amqp` (the change broadcaster).

### 3.3 Changing config without restarting
Values read through `@ConfigurationProperties` can be reloaded live:
```bash
# 1. change accounts.yml in the Git repo and push
# 2. tell ONE service to reload
curl -X POST localhost:8080/actuator/refresh
# 3. or tell ALL services at once through the message bus
curl -X POST localhost:8080/actuator/busrefresh
```
`/actuator/refresh` reloads just that instance. `/actuator/busrefresh` publishes an event on RabbitMQ so **every** instance reloads. The management config (`management.endpoints.web.exposure.include: "*"`)
is what exposes these endpoints. **Never expose `*` to the internet.**

### 3.4 Docker Compose with profiles (introduced here)
`section6/v2-spring-cloud-config/docker-compose/default/common-config.yml`:
```yaml
6  microservice-base-config:
7    extends:
8      service: network-deploy-service
9    deploy:
10     resources:
11       limits:
12         memory: 700m
13   environment:
14     SPRING_RABBITMQ_HOST: "rabbit"
16 microservice-configserver-config:
17   extends:
18     service: microservice-base-config
19   environment:
20     SPRING_PROFILES_ACTIVE: default
21     SPRING_CONFIG_IMPORT: configserver:http://configserver:8071/
```
- **Lines 6–12 and 16–21** are reusable *templates*. Other services `extends` them so nothing is repeated.
- **Line 14**: inside Docker, RabbitMQ is at host `rabbit`, not `localhost` (env var beats file).
- **Lines 20–21**: profile and config server URL, both injected via environment variables. **This is the 12-factor idea in action:** same image, behaviour set from outside.
- There are three folders: `default/`, `qa/`, `prod/`. They differ only in `SPRING_PROFILES_ACTIVE`, so `docker compose up` in `qa/` makes every service fetch `*-qa.yml`.
- `docker-compose.yml` adds a `rabbit` service (`rabbitmq:4-management`, ports 5672 and 15672 for the UI). The config server `depends_on: rabbit: condition: service_healthy`.

## 4. Try it and break it
1. **v1:** run with `--spring.profiles.active=prod` and hit `/api/contact-info`: different contact name than with `qa`.
2. **v2:** start the config server, then `curl localhost:8071/accounts/prod`. You'll see the JSON Spring will inject, with the profile-specific file taking priority.
3. Call `/api/contact-info`, change the value in the config repo, `POST /actuator/refresh`, call again: new value, **no restart**.
4. `curl -X POST localhost:8071/encrypt -d 'mySecret'` returns ciphertext; store it as `{cipher}…` in YAML.

## 5. Traps and senior notes
- **Config Server is a critical dependency.** If it's down, new instances can't start. Keep it highly available and cache config.
- **Secrets don't belong in Git**, even encrypted, in most companies. Use Vault or your cloud's secret manager and keep only references in config.
- **Order of precedence surprises people.** When "my YAML change has no effect", suspect an environment variable set on the container.
- **`optional:configserver` hides mistakes**: a typo'd URL quietly falls back to defaults. Use non-optional in real environments.
