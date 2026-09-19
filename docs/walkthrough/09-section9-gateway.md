# Chapter 9: The gateway / edge server (`section9/gatewayserver`)

New in this section: the **`gatewayserver`** service (Spring Cloud Gateway).

## 1. The problem
After chapter 8, a mobile app wanting customer data would need to know the address of accounts (8080), loans (8090), cards (9000)...
- Clients are coupled to your internal layout. Move a service and every client breaks.
- Cross-cutting concerns (security, logging, rate limiting, tracing ids) would be copied into every service.
- Every internal service would be exposed to the internet: a big attack surface.

## 2. The idea: one front door
An **API Gateway** (or *edge server*) is the single public entry point:

```
Client ──► GATEWAY :8072 ──► routes by URL path ──► ACCOUNTS / LOANS / CARDS (found via Eureka)
              │
              └─ applies filters to *every* request: correlation id, security, resilience, logging …
```
Think of the **reception desk of an office building**: visitors only ever talk to reception; reception knows which floor to send them to, checks IDs, and logs who
came in. The internal offices don't need their own security guards.

Spring Cloud Gateway is built on **WebFlux** (non-blocking, reactive), so it can handle many concurrent connections with few threads. That's why you'll see `Mono` in this chapter.
Its three vocabulary words:

| Word | Meaning |
|------|---------|
| **Route** | A rule: "if the request matches X, forward it to Y" |
| **Predicate** | The "if" (path, header, method…) |
| **Filter** | A step that changes the request or response (rewrite the path, add a header, …) |

## 3. Code walkthrough

### 3.1 Dependencies (`pom.xml`)
`spring-cloud-starter-gateway-server-webflux` (the gateway), `spring-cloud-starter-netflix-eureka-client` (to find services), `spring-cloud-starter-config` (config from the config server) and actuator.
Notice there's **no `spring-boot-starter-web`**: gateway is reactive, and mixing in the servlet stack breaks it.

### 3.2 Routes: `GatewayserverApplication.java`
```java
2  @SpringBootApplication
3  public class GatewayserverApplication {
4  	public static void main(String[] args) {
5  		SpringApplication.run(GatewayserverApplication.class, args);
6  	}
7  	@Bean
8  	public RouteLocator eazyBankRouteConfig(RouteLocatorBuilder routeLocatorBuilder) {
9  		return routeLocatorBuilder.routes()
10 				.route(p -> p
11 						.path("/eazybank/accounts/**")
12 						.filters( f -> f.rewritePath("/eazybank/accounts/(?<segment>.*)","/${segment}")
13 								.addResponseHeader("X-Response-Time", LocalDateTime.now().toString()))
14 						.uri("lb://ACCOUNTS"))
15 			.route(p -> p
16 					.path("/eazybank/loans/**")
17 					.filters( f -> f.rewritePath("/eazybank/loans/(?<segment>.*)","/${segment}")
18 							.addResponseHeader("X-Response-Time", LocalDateTime.now().toString()))
19 					.uri("lb://LOANS"))
20 			.route(p -> p
21 					.path("/eazybank/cards/**")
22 					.filters( f -> f.rewritePath("/eazybank/cards/(?<segment>.*)","/${segment}")
23 							.addResponseHeader("X-Response-Time", LocalDateTime.now().toString()))
24 					.uri("lb://CARDS")).build();
25 	}
26 }
```
Walk through one request: `GET http://localhost:8072/eazybank/accounts/api/fetch?mobileNumber=4354437687`

- **Line 7–8, `@Bean RouteLocator`**: we register a bean that *defines the routing table* in Java (routes can also be written in YAML; Java is more flexible).
- **Line 9**: `routes()` starts a builder. Each `.route(p -> p …)` is one rule.
- **Line 11, `.path("/eazybank/accounts/**")`**: the **predicate**. `**` matches any depth, so our request matches the *accounts* route.
- **Line 12, `rewritePath(regex, replacement)`**: strips the public prefix. The regex `/eazybank/accounts/(?<segment>.*)` captures everything after the prefix into a **named group**
  `segment`; the replacement `/${segment}` re-emits it. So `/eazybank/accounts/api/fetch` becomes `/api/fetch`, which is what the accounts service actually understands.
  *The prefix is public branding; the service should not know about it.*
- **Line 13, `addResponseHeader("X-Response-Time", …)`**: adds a header to every response. **Trap:** `LocalDateTime.now()` runs **once when the route is built at startup**, so the
  value is frozen at startup time, not per request. Fine for a demo; a real per-request timestamp needs a custom filter.
- **Line 14, `.uri("lb://ACCOUNTS")`**: the **target**. `lb://` means *"resolve this name using the load balancer"*. Gateway asks Eureka for instances of `ACCOUNTS`, picks one,
  and forwards to e.g. `http://172.18.0.7:8080/api/fetch?...`. **`ACCOUNTS` must match the name registered in Eureka** (chapter 8).
- **Lines 15–24**: the same for loans and cards. Only the path and the target change.

### 3.3 Turning off the automatic routes
`application.yml`:
```yaml
1  spring:
2    application:
3      name: "gatewayserver"
4    config:
5      import: "optional:configserver:http://localhost:8071/"
6    cloud:
7      gateway:
8        server:
9          webflux:
10           discovery:
11             locator:
12               enabled: false
13               lowerCaseServiceId: true
15 management:
16   endpoints:
17     web:
18       exposure:
19         include: "*"
20   endpoint:
21     gateway:
22       access: unrestricted
```
- **Lines 10–13, the discovery locator**: if `enabled: true`, Gateway creates a route for **every** service in Eureka automatically (`/accounts/**`, `/loans/**`…).
  Convenient, but you'd expose everything, including services you don't want public. We set it to `false` and route **explicitly** (which is why
  `/accounts/api/…` without the `eazybank` prefix returns 404). `lowerCaseServiceId` only matters if the locator is on.
- **Lines 20–22**: makes gateway's own actuator endpoint `/actuator/gateway/routes` available so you can see the live routing table.
- The **port 8072** isn't in this file. As in chapter 8, the Config Server supplies it: I queried `localhost:8071/gatewayserver/default` and got `server.port = 8072` from the
  config repo's `gatewayserver.yml`.

### 3.4 A global filter: the correlation id
**Why?** One customer click touches gateway → accounts → loans/cards. When something is slow or wrong, you need to find *all the log lines belonging to that one click*.
The trick: stamp every request with a unique id at the edge and pass it along.

`FilterUtility.java` (helper):
```java
2  @Component
3  public class FilterUtility {
4      public static final String CORRELATION_ID = "eazybank-correlation-id";
5      public String getCorrelationId(HttpHeaders requestHeaders) {
6          if (requestHeaders.get(CORRELATION_ID) != null) {
7              List<String> requestHeaderList = requestHeaders.get(CORRELATION_ID);
8              return requestHeaderList.stream().findFirst().get();
9          } else {
10             return null;
11         }
12     }
13     public ServerWebExchange setRequestHeader(ServerWebExchange exchange, String name, String value) {
14         return exchange.mutate().request(exchange.getRequest().mutate().header(name, value).build()).build();
15     }
16     public ServerWebExchange setCorrelationId(ServerWebExchange exchange, String correlationId) {
17         return this.setRequestHeader(exchange, CORRELATION_ID, correlationId);
18     }
19 }
```
- **Line 4**: the header name lives in **one constant** (no typos scattered around).
- **Lines 5–12**: read the header if present, else `null`.
- **Lines 13–15**: requests in WebFlux are **immutable**. To add a header you `mutate()` the request, add it, `build()`, then rebuild the exchange. The method returns the *new* exchange:
  ignoring the return value is a classic bug.

`RequestTraceFilter.java` (runs *before* routing):
```java
2  @Order(1)
3  @Component
4  public class RequestTraceFilter implements GlobalFilter {
9      public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
10         HttpHeaders requestHeaders = exchange.getRequest().getHeaders();
11         if (isCorrelationIdPresent(requestHeaders)) {
12             logger.debug("eazyBank-correlation-id found in RequestTraceFilter : {}", ...);
14         } else {
15             String correlationID = generateCorrelationId();
16             exchange = filterUtility.setCorrelationId(exchange, correlationID);
17             logger.debug("eazyBank-correlation-id generated in RequestTraceFilter : {}", correlationID);
18         }
19         return chain.filter(exchange);
20     }
29     private String generateCorrelationId() { return java.util.UUID.randomUUID().toString(); }
```
- **Line 4, `implements GlobalFilter`**: applies to **every route**, no per-route wiring needed.
- **Line 2, `@Order(1)`**: lower number = earlier. This one should run first so everything after can rely on the id.
- **Lines 11–18**: if the client (or an upstream proxy) already sent an id, **keep it** (so traces can span systems); otherwise generate a fresh UUID and attach it.
- **Line 19, `return chain.filter(exchange)`**: "continue to the next filter / the route". **Forgetting this line would hang every request.** It returns a `Mono<Void>`: a promise of completion, and
  in reactive code nothing happens until something subscribes.

`ResponseTraceFilter.java` (runs *after* the downstream responds):
```java
2  @Configuration
3  public class ResponseTraceFilter {
7      @Bean
8      public GlobalFilter postGlobalFilter() {
9          return (exchange, chain) -> {
10             return chain.filter(exchange).then(Mono.fromRunnable(() -> {
11                 HttpHeaders requestHeaders = exchange.getRequest().getHeaders();
12                 String correlationId = filterUtility.getCorrelationId(requestHeaders);
13                 logger.debug("Updated the correlation id to the outbound headers: {}", correlationId);
14                 exchange.getResponse().getHeaders().add(FilterUtility.CORRELATION_ID, correlationId);
15             }));
16         };
17     }
```
- **Line 10**: `chain.filter(exchange)` runs the rest of the chain **and the downstream call**; `.then(…)` schedules our code to run **afterwards**. This *pre/post* pattern is how one
  filter class handles both directions.
- **Line 14**: copy the id onto the **response**, so the caller (and support staff reading a screenshot) can quote the id to find the logs.
- Filters defined as a `@Bean` lambda (this one) or as a class implementing `GlobalFilter` (the request one) are equivalent; the course shows both styles.

### 3.5 Compose: the gateway starts last
```yaml
103 gatewayserver:
104   image: "eazybytes/gatewayserver:s9"
105   container_name: gatewayserver-ms
106   ports:
107     - "8072:8072"
108   depends_on:
109     accounts: {condition: service_healthy}
110     loans:    {condition: service_healthy}
111     cards:    {condition: service_healthy}
```
The gateway waits for the services it routes to. Only ports **8070, 8071, 8072** are published in later sections: the business services become reachable **only** through the gateway.

## 4. Try it and break it
```bash
curl -i http://localhost:8072/eazybank/accounts/api/contact-info
#  → 200, and look at the headers:  eazybank-correlation-id: <uuid>   X-Response-Time: <startup time>
curl -i http://localhost:8072/accounts/api/contact-info                    # → 404 (locator disabled, wrong prefix)
curl -i -H "eazybank-correlation-id: my-test-123" http://localhost:8072/eazybank/loans/api/contact-info
#  → response echoes "my-test-123": the filter kept our id
curl http://localhost:8072/actuator/gateway/routes                         # the live routing table
```
Then search the logs for the id: `docker logs gatewayserver-ms | grep my-test-123`.

## 5. Traps and senior notes
- **Route order and specificity matter.** The first matching route wins; put specific paths before broad ones.
- **The gateway is a single point of failure and a bottleneck.** Run several instances behind a real load balancer and keep it *thin*: no business logic.
- **Never use blocking calls (JDBC, `Thread.sleep`) in a reactive filter.** You'd block the few event-loop threads and stall all traffic.
- **The correlation id is only useful if every service logs it and forwards it.** Chapter 10 adds it to the Feign calls; chapter 11 adds proper distributed tracing (trace ids) which supersedes hand-rolled ids in many companies.
