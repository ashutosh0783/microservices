# Chapter 10: Making microservices resilient (`section_10/`)

New in this section: **Resilience4j** on the gateway *and* inside `accounts`; `LoansFallback`/`CardsFallback`; a Redis-backed rate limiter; a `FallbackController` on the gateway.
(The code below is from `section_14`, which contains the final version of everything added here. Values that differ from `section_10` are noted.)

## 1. The problem
Networks fail. Services are slow, restart, or die. In chapter 8, `accounts` calls `loans` with what *looks* like a method call. If `loans` hangs:

1. accounts' request threads pile up waiting for loans,
2. accounts runs out of threads and stops answering,
3. the gateway's calls to accounts pile up,
4. the entire system is down because **one** small service was slow.

This is a **cascading failure**. The cure is to assume every remote call *will* fail and decide in advance what happens then.

## 2. The idea: five defensive patterns

| Pattern | Analogy | What it does |
|---------|---------|--------------|
| **Timeout** | "I'll wait 10 seconds for the waiter, then leave" | Never wait forever |
| **Retry** | Redial a busy number, waiting a bit longer each time | Recover from *transient* glitches |
| **Circuit breaker** | The breaker in your fuse box | After too many failures, **stop calling** for a while, then test carefully |
| **Rate limiter** | A bouncer letting N people in per minute | Protect a service from being overwhelmed |
| **Fallback** | "Kitchen's closed, but here's the dessert menu" | Return something sensible instead of an error |

The circuit breaker has three states:
```
CLOSED ──(failure rate ≥ 50% over last 10 calls)──► OPEN ──(wait 10 s)──► HALF-OPEN
   ▲                                                  │ calls fail fast,           │ allow 2 test calls
   └──────────────(test calls succeed)────────────────┴── no load on the sick service ┘  (fail → back to OPEN)
```
While OPEN, callers get an **instant** failure or fallback instead of tying up a thread for seconds. That protects *both* sides: the caller stays healthy and the sick service gets breathing room.

## 3. Code walkthrough

### 3.1 Gateway-level resilience: `GatewayserverApplication.java`
```java
8  public RouteLocator eazyBankRouteConfig(RouteLocatorBuilder routeLocatorBuilder) {
9      return routeLocatorBuilder.routes()
10         .route(p -> p
11             .path("/eazybank/accounts/**")
12             .filters( f -> f.rewritePath("/eazybank/accounts/(?<segment>.*)","/${segment}")
13                 .addResponseHeader("X-Response-Time", LocalDateTime.now().toString())
14                 .circuitBreaker(config -> config.setName("accountsCircuitBreaker")
15                     .setFallbackUri("forward:/contactSupport")))
16             .uri("lb://ACCOUNTS"))
17         .route(p -> p
18             .path("/eazybank/loans/**")
19             .filters( f -> f.rewritePath("/eazybank/loans/(?<segment>.*)","/${segment}")
20                 .addResponseHeader("X-Response-Time", LocalDateTime.now().toString())
21                 .retry(retryConfig -> retryConfig.setRetries(3)
22                     .setMethods(HttpMethod.GET)
23                     .setBackoff(Duration.ofMillis(100),Duration.ofMillis(1000),2,true)))
24             .uri("lb://LOANS"))
25         .route(p -> p
26             .path("/eazybank/cards/**")
27             .filters( f -> f.rewritePath("/eazybank/cards/(?<segment>.*)","/${segment}")
28                 .addResponseHeader("X-Response-Time", LocalDateTime.now().toString())
29                 .requestRateLimiter(config -> config.setRateLimiter(redisRateLimiter())
30                     .setKeyResolver(userKeyResolver())))
31             .uri("lb://CARDS")).build();
32 }
```
Three routes, three *different* patterns, so you can compare them:

**Accounts route: circuit breaker (lines 14–15)**
- `circuitBreaker(config -> config.setName("accountsCircuitBreaker") …)`: wrap calls to accounts in a breaker with this name (the name is how you
  reference it in config and in metrics).
- `setFallbackUri("forward:/contactSupport")`: when the breaker is open, or the call fails or times out, **forward internally** to the gateway's own `/contactSupport`
  endpoint (3.2) instead of returning a raw error. `forward:` means "handle this inside the gateway", not "send the client a redirect".

**Loans route: retry (lines 21–23)**
- `setRetries(3)`: up to 3 *additional* attempts. **`setMethods(HttpMethod.GET)`: only for GET.** This is crucial: GET is **idempotent** (safe to repeat), whereas retrying a
  `POST /create` after a timeout could create the loan twice. Never blanket-retry writes.
- `setBackoff(firstBackoff=100ms, maxBackoff=1000ms, factor=2, basedOnPreviousValue=true)`: wait 100 ms, then 200, 400 … capped at 1 s. **Exponential back-off**
  gives a struggling service time to recover; retrying instantly in a tight loop hammers it when it's already down.

**Cards route: rate limiter (lines 29–30)**
- `requestRateLimiter(...)` needs two pieces: *how much* (`RedisRateLimiter`) and *for whom* (`KeyResolver`). They are defined as beans below.

```java
36 @Bean
37 public Customizer<ReactiveResilience4JCircuitBreakerFactory> defaultCustomizer() {
38 	return factory -> factory.configureDefault(id -> new Resilience4JConfigBuilder(id)
39 			.circuitBreakerConfig(CircuitBreakerConfig.ofDefaults())
40 			.timeLimiterConfig(TimeLimiterConfig.custom().timeoutDuration(Duration.ofSeconds(10))
41 					.build()).build());
42 }
43 @Bean
44 public RedisRateLimiter redisRateLimiter() {
45 	return new RedisRateLimiter(1, 1, 1);
46 }
47 @Bean
48 KeyResolver userKeyResolver() {
49 	return exchange -> Mono.justOrEmpty(exchange.getRequest().getHeaders().getFirst("user"))
50 			.defaultIfEmpty("anonymous");
51 }
```
- **Lines 37–41**: default settings for every gateway circuit breaker: `CircuitBreakerConfig.ofDefaults()` plus a **`TimeLimiter` of 10 s**: any call taking longer counts as a failure.
  (In `section_10` this was 4 s; `section_14` uses 10 s.) This is the **timeout** pattern; without it a hung service can hold a connection indefinitely.
- **Line 45, `new RedisRateLimiter(1, 1, 1)`**: arguments are `replenishRate`, `burstCapacity`, `requestedTokens`. It's a **token bucket**: the bucket refills 1 token per second, holds at most 1, and each
  request costs 1 token. Effectively **1 request per second per key**. Tokens live in **Redis**, so if you run three gateway instances they share one count (in-memory counters would let
  through three times the limit).
- **Lines 48–51, `KeyResolver`**: "who is this request from?". It uses the value of a request header called `user`, and **`anonymous`** if there is none. Each key gets its own bucket.
  **Trap:** trusting a client-supplied header is fine for a demo but trivially spoofed. Real systems key on the authenticated principal or client IP.

`FallbackController.java` (the target of `forward:/contactSupport`):
```java
5  @RestController
6  public class FallbackController {
7      @RequestMapping("/contactSupport")
8      public Mono<String> contactSupport() {
9          return Mono.just("An error occurred. Please try after some time or contact support team!!!");
10     }
11 }
```
A friendly message with HTTP 200 (`Mono<String>`: a reactive one-value response). In a real system you'd return a structured error body and an appropriate status.

**Redis wiring** in `gatewayserver/src/main/resources/application.yml`:
```yaml
1  spring:
2    cloud:
3      gateway:
4        server:
5          webflux:
6            httpclient:
7              connect-timeout: 1000
8              response-timeout: 10s
9    data:
10     redis:
11       connect-timeout: 2s
12       host: localhost
13       port: 6379
14       timeout: 1s
15 resilience4j.circuitbreaker:
16   configs:
17     default:
18       slidingWindowSize: 10
19       permittedNumberOfCallsInHalfOpenState: 2
20       failureRateThreshold: 50
21       waitDurationInOpenState: 10000
```
- **Lines 7–8**: HTTP-level timeouts: give up connecting after 1 s, and waiting for a response after 10 s.
- **Lines 11–14**: Redis timeouts: short, so a broken Redis doesn't freeze the gateway.
- **Lines 15–21, the circuit breaker's brain**: judge the **last 10 calls** (`slidingWindowSize`); if **≥50% failed**, open; stay open **10 000 ms**; then, in half-open, allow **2** trial calls.
  Exactly the diagram in section 2.
- The compose file for this section adds a **`redis`** container; the `section_14` compose file no longer contains one (see the trap below).

### 3.2 Service-level resilience: inside `accounts`

**Feign + circuit breaker + fallback**, `LoansFeignClient.java`:
```java
2  @FeignClient(name="loans",fallback = LoansFallback.class)
3  public interface LoansFeignClient {
4      @GetMapping(value = "/api/fetch",consumes = "application/json")
5      public ResponseEntity<LoansDto> fetchLoanDetails(@RequestHeader("eazybank-correlation-id")
6                                                           String correlationId, @RequestParam String mobileNumber);
7  }
```
- **Line 2, `fallback = LoansFallback.class`**: if the call fails (or the breaker is open), Feign calls the **same method on this fallback class** instead.
  The config switch `spring.cloud.openfeign.circuitbreaker.enabled: true` (in `accounts`' `application.yml`) is what wraps Feign calls in a circuit breaker; without it the `fallback`
  attribute is ignored.
- **Lines 5–6**: the correlation id from chapter 9 is now **forwarded** as a header, so loans' logs carry the same id. The gateway generated it; accounts passes it on.

`LoansFallback.java`:
```java
2  @Component
3  public class LoansFallback implements LoansFeignClient{
4      @Override
5      public ResponseEntity<LoansDto> fetchLoanDetails(String correlationId, String mobileNumber) {
6          return null;
7      }
8  }
```
- **Line 3, `implements LoansFeignClient`**: the compiler forces the fallback to have the same methods. **Line 2, `@Component`** makes it a bean so Feign can find it.
- **Line 6, `return null`** is the simplest fallback: "no loan data available". The caller must therefore **handle null**. `CustomersServiceImpl` in `section_14` does:
```java
if(null != loansDtoResponseEntity) {
    customerDetailsDto.setLoansDto(loansDtoResponseEntity.getBody());
}
```
  (Compare chapter 8, where this call was unguarded and a null would have thrown a `NullPointerException`.) Other fallbacks return cached data, defaults, or a "degraded" marker.

**Retry and rate limiter on plain methods**, `AccountsController.java`:
```java
204 @Retry(name = "getBuildInfo",fallbackMethod = "getBuildInfoFallback")
205 @GetMapping("/build-info")
206 public ResponseEntity<String> getBuildInfo() {
207     logger.debug("getBuildInfo() method Invoked");
208     return ResponseEntity.status(HttpStatus.OK).body(buildVersion);
211 }
213 public ResponseEntity<String> getBuildInfoFallback(Throwable throwable) {
214     logger.debug("getBuildInfoFallback() method Invoked");
215     return ResponseEntity.status(HttpStatus.OK).body("0.9");
218 }
238 @RateLimiter(name= "getJavaVersion", fallbackMethod = "getJavaVersionFallback")
239 @GetMapping("/java-version")
240 public ResponseEntity<String> getJavaVersion() {
241     return ResponseEntity.status(HttpStatus.OK).body(environment.getProperty("JAVA_HOME"));
244 }
246 public ResponseEntity<String> getJavaVersionFallback(Throwable throwable) {
247     return ResponseEntity.status(HttpStatus.OK).body("Java 21");
250 }
```
- **Line 204, `@Retry(name=…, fallbackMethod=…)`**: Resilience4j wraps the method in a retry using the config named `getBuildInfo`. If the method keeps throwing, after the last attempt it calls **`getBuildInfoFallback`**.
  **The rule:** the fallback must have the **same parameters as the original plus a trailing `Throwable`** (here none + `Throwable`), and the same return type, or Resilience4j can't find it.
- **Line 238, `@RateLimiter`**: allow only N calls per period; extra calls invoke `getJavaVersionFallback` (returns the literal `"Java 21"`).
- These endpoints are deliberately trivial: they exist so you can *watch* the annotations work. (Annotations rely on Spring AOP proxies, so they only work when the method is called **from outside the bean**, not from
  another method of the same class.)

Their settings, in `accounts`' `application.yml`:
```yaml
1  resilience4j.circuitbreaker:
2    configs:
3      default:
4        slidingWindowSize: 10
5        permittedNumberOfCallsInHalfOpenState: 2
6        failureRateThreshold: 50
7        waitDurationInOpenState: 10000
9  resilience4j.retry:
10   configs:
11     default:
12       maxAttempts: 3
13       waitDuration: 500
14       enableExponentialBackoff: true
15       exponentialBackoffMultiplier: 2
16       ignoreExceptions:
17         - java.lang.NullPointerException
18       retryExceptions:
19         - java.util.concurrent.TimeoutException
21 resilience4j.ratelimiter:
22   configs:
23     default:
24       timeoutDuration: 1000
25       limitRefreshPeriod: 5000
26       limitForPeriod: 1
```
- **Lines 12–15**: 3 attempts, 500 ms, 1 s, 2 s apart (doubling). **Lines 16–19**: *which* exceptions matter: **don't retry** a `NullPointerException` (a bug never fixes itself on retry); **do retry** timeouts.
- **Lines 24–26**: `limitForPeriod: 1` per `limitRefreshPeriod: 5000` ms → **1 call every 5 s**. `timeoutDuration: 1000` means a caller may wait up to 1 s for a permit before being rejected.
- `configs.default` is the shared template; the names used in annotations (`getBuildInfo`, `getJavaVersion`) pick up these defaults unless an `instances:` block overrides them.

## 4. Try it and break it (verified on the running stack)
I ran these against the stack in this repo:

```bash
# 1) Graceful degradation with a fallback
curl "localhost:8072/eazybank/accounts/api/fetchCustomerDetails?mobileNumber=4354437687"   # all three blocks present
docker stop loans-ms
curl "localhost:8072/eazybank/accounts/api/fetchCustomerDetails?mobileNumber=4354437687"
# observed: HTTP 200, but  "loansDto": null   (LoansFallback returned null)  ← the key is present, value null
```
```bash
# 2) Rate limiter + fallback
curl localhost:8072/eazybank/accounts/api/java-version   # observed: "/opt/java/openjdk"  (real value)
curl localhost:8072/eazybank/accounts/api/java-version   # observed: "Java 21"            (fallback: 2nd call within 5 s)
```
```bash
# 3) After  docker start loans-ms , the gateway briefly answered:
#    503 "Unable to find instance for LOANS"
```
Observation 3 is *not* a bug; it's chapter 8's lesson made visible. The restarted `loans` had to re-register with Eureka, and the gateway only refreshes its cached registry every ~30 s, so for a while
it still believed there was no LOANS instance. **Discovery is eventually consistent.** (Retrying a few seconds later succeeded.)

More experiments:
- Watch the breaker state: `curl localhost:8072/actuator/circuitbreakers`. On the running stack it reports `"accountsCircuitBreaker": {"state":"CLOSED", "failureRateThreshold":"50.0%", ...}`. Also see `/actuator/circuitbreakerevents`, `/actuator/ratelimiters` and `/actuator/metrics`.
- Hit the cards route twice within a second with `-H "user: bob"`, and with Redis running the second call is throttled (HTTP 429).
- Use Apache Benchmark from the course README: `ab -n 10 -c 2 -v 3 http://localhost:8072/eazybank/cards/api/contact-info`.

## 5. Traps and senior notes
- **In `section_14` the Redis container is missing** from Docker Compose, so the cards limiter has nothing to count with. Requests still succeed (I saw HTTP 201 on cards) because the
  limiter **fails open**: if it can't reach Redis it lets traffic through rather than blocking everyone. Good default for availability, but it means *you silently have no rate limiting*. Monitor for it.
- **A fallback that returns `null` moves the problem, it doesn't remove it.** Decide per case: stale cache, default value, or an honest "temporarily unavailable" field.
- **Retries multiply load.** 3 retries × 3 layers = 27 calls hitting a struggling service. Retry at *one* layer, and only idempotent calls, with jitter and a cap.
- **Tune with data.** `50%`, `10 calls`, `10 s` are textbook defaults, not truths. Use your metrics to choose them.
- **Timeouts come first.** A circuit breaker can't help if every call hangs for minutes because nothing times out.
