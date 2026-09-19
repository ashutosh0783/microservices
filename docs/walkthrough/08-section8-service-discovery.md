# Chapter 8: Service discovery and registration (`section8/`)

New in this section: the **`eurekaserver`** service, the **Feign clients** in `accounts`, and the first *aggregation* endpoint `fetchCustomerDetails`.

## 1. The problem
The accounts service must call loans and cards. How does it know **where** they are?

- Hard-coding `http://localhost:8090` works on your laptop only.
- In Docker or Kubernetes, IP addresses change on every restart, and you may run **three copies** of loans for load.
- If a copy dies, callers must stop sending traffic to it.

## 2. The idea: a phone book that keeps itself up to date
A **service registry** (here **Netflix Eureka**) is a directory of *running* instances:

```
1. REGISTER   loans starts  ──► Eureka: "LOANS is at 172.18.0.5:8090"
2. HEARTBEAT  loans ──► Eureka every 30 s: "still alive"     (no heartbeat → entry removed)
3. LOOKUP     accounts ──► Eureka: "who is LOANS?"  ◄── [172.18.0.5:8090, 172.18.0.9:8090]
4. CALL       accounts picks one instance and calls it directly
```
Step 4 is why this is called **client-side load balancing**: the *caller* chooses the instance (round-robin by default), not a central load balancer.
The caller uses a **logical name** (`loans`), never an address.

## 3. Code walkthrough

### 3.1 The registry server: 8 lines of code
`eurekaserver/.../EurekaserverApplication.java`:
```java
2  @SpringBootApplication
3  @EnableEurekaServer
4  public class EurekaserverApplication {
5  	public static void main(String[] args) {
6  		SpringApplication.run(EurekaserverApplication.class, args);
7  	}
8  }
```
- **Line 3, `@EnableEurekaServer`** is the whole feature. Together with the dependency `spring-cloud-starter-netflix-eureka-server` it turns the app into a registry with a
  dashboard at `/`.

Its `application.yml` is tiny:
```yaml
1  spring:
2    application:
3      name: "eurekaserver"
4    config:
5      import: "optional:configserver:http://localhost:8071/"
```
- Notice there's **no port and no `eureka.*` setting** here. They arrive from the **Config Server**: I asked the running config server for
  `curl localhost:8071/eurekaserver/default` and it returns (from the config Git repo's `eurekaserver.yml`):
  `server.port: 8070`, `eureka.client.registerWithEureka: false`, `eureka.client.fetchRegistry: false`.
  The last two mean "the registry itself should not register with, or fetch from, another registry". This is a good example of chapter 6 in action.

### 3.2 A service becomes a Eureka client
Added to `accounts` (also loans, cards): the dependency `spring-cloud-starter-netflix-eureka-client`, and this in `application.yml`:
```yaml
1  eureka:
2    instance:
3      preferIpAddress: true
4    client:
5      fetchRegistry: true
6      registerWithEureka: true
7      serviceUrl:
8        defaultZone: http://localhost:8070/eureka/
9  info:
10   app:
11     name: "accounts"
12     description: "Eazy Bank Accounts Application"
13     version: "1.0.0"
```
- **Line 3, `preferIpAddress`**: register with the container's IP instead of its hostname. Container hostnames are random IDs that other containers can't
  resolve; IPs work on the Docker network.
- **Line 6, `registerWithEureka`**: "publish me in the registry" (this is step 1). **Line 5, `fetchRegistry`**: "download the phone book so I can call others" (step 3).
- **Line 8, `defaultZone`**: where Eureka lives. In Docker Compose it's overridden with the env var
  `EUREKA_CLIENT_SERVICEURL_DEFAULTZONE: http://eurekaserver:8070/eureka/` (the compose template `microservice-eureka-config`).
- **Lines 9–13, `info.*`**: shown at `/actuator/info` (needs `management.info.env.enabled: true`) and visible in the Eureka dashboard: handy for "which version is running?"
- The name that appears in Eureka is `spring.application.name`, upper-cased: **ACCOUNTS**, **LOANS**, **CARDS**. That's the *logical name*.

### 3.3 Calling another service with OpenFeign
Without Feign you'd write `RestTemplate`/`WebClient` code, build URLs by hand and parse JSON. With Feign you **declare an interface** and Spring writes the HTTP client.

`CardsFeignClient.java`:
```java
2  @FeignClient("cards")
3  public interface CardsFeignClient {
4      @GetMapping(value = "/api/fetch",consumes = "application/json")
5      public ResponseEntity<CardsDto> fetchCardDetails(@RequestParam String mobileNumber);
6  }
```
- **Line 2, `@FeignClient("cards")`**: "calls to this interface go to the service named `cards`". Spring asks Eureka for instances of `CARDS` and load-balances between them
  (Spring Cloud LoadBalancer). No host or port appears anywhere.
- **Line 4**: `@GetMapping` here **describes the remote endpoint** (the same annotation you use in a controller), so this line means "issue `GET /api/fetch`". It exactly
  mirrors the controller in the cards service; if cards changes its path, this line must change too (a coupling to be aware of).
- **Line 5**: the return type `ResponseEntity<CardsDto>` gives you status, headers and the body. `@RequestParam String mobileNumber` becomes `?mobileNumber=…`.
- `CardsDto` is a **copy of the DTO inside the accounts project**. Services don't share classes (chapter 20 revisits this trade-off).

`LoansFeignClient` is identical with `@FeignClient("loans")` and `LoansDto`. The application class gets `@EnableFeignClients` so Spring scans for these interfaces.

### 3.4 The aggregator: `CustomersServiceImpl`
```java
23 public class CustomersServiceImpl implements ICustomersService {
25     private AccountsRepository accountsRepository;
26     private CustomerRepository customerRepository;
27     private CardsFeignClient cardsFeignClient;
28     private LoansFeignClient loansFeignClient;
35     public CustomerDetailsDto fetchCustomerDetails(String mobileNumber) {
36         Customer customer = customerRepository.findByMobileNumber(mobileNumber).orElseThrow(
37                 () -> new ResourceNotFoundException("Customer", "mobileNumber", mobileNumber));
39         Accounts accounts = accountsRepository.findByCustomerId(customer.getCustomerId()).orElseThrow(
40                 () -> new ResourceNotFoundException("Account", "customerId", customer.getCustomerId().toString()));
43         CustomerDetailsDto customerDetailsDto = CustomerMapper.mapToCustomerDetailsDto(customer, new CustomerDetailsDto());
44         customerDetailsDto.setAccountsDto(AccountsMapper.mapToAccountsDto(accounts, new AccountsDto()));
46         ResponseEntity<LoansDto> loansDtoResponseEntity = loansFeignClient.fetchLoanDetails(mobileNumber);
47         customerDetailsDto.setLoansDto(loansDtoResponseEntity.getBody());
49         ResponseEntity<CardsDto> cardsDtoResponseEntity = cardsFeignClient.fetchCardDetails(mobileNumber);
50         customerDetailsDto.setCardsDto(cardsDtoResponseEntity.getBody());
52         return customerDetailsDto;
54     }
```
- **Lines 25–28**: two **local** repositories (accounts owns customer and account data) and two **remote** clients (loans and cards own theirs). This is the
  database-per-service rule from chapter 7 in practice: *reach other services' data only through their API*.
- **Lines 36–41**: local data first. If the customer doesn't exist, we stop before making network calls.
- **Line 46**: looks like a normal method call, but it's an **HTTP call across the network**. It can be slow, fail, or time out. That is the exact problem chapter 10 solves.
- **Lines 47, 50**: `.getBody()` extracts the DTO from the response and puts it in the combined `CustomerDetailsDto`
  (name, email, mobile, and nested `accountsDto`, `loansDto`, `cardsDto`).
- Note: in this section, if loans returns an error, **the whole call fails**. Keep that in mind for chapter 10.

`CustomerController` exposes it:
```java
33 @GetMapping("/fetchCustomerDetails")
34 public ResponseEntity<CustomerDetailsDto> fetchCustomerDetails(@RequestParam
35              @Pattern(regexp="(^$|[0-9]{10})",message = "Mobile number must be 10 digits") String mobileNumber){
36     CustomerDetailsDto customerDetailsDto = iCustomersService.fetchCustomerDetails(mobileNumber);
37     return ResponseEntity.status(HttpStatus.SC_OK).body(customerDetailsDto);
38 }
```
- It's a separate controller (`CustomerController`) from `AccountsController` because it's about the *customer view* spanning services, not about the accounts resource.

### 3.5 Compose: order matters
`section8/docker-compose/default/docker-compose.yml` (excerpt):
```yaml
17 eurekaserver:
18   image: "eazybytes/eurekaserver:s8"
19   container_name: eurekaserver-ms
20   ports:
21     - "8070:8070"
22   depends_on:
23     configserver:
24       condition: service_healthy
...
37 accounts:
...
42   depends_on:
43     configserver:
44       condition: service_healthy
45     eurekaserver:
46       condition: service_healthy
```
The chain is now: **config server → Eureka → business services**. Config first (everybody needs their settings), Eureka next (so registration succeeds).

## 4. Try it and break it
1. Open **http://localhost:8070**: the "Instances currently registered with Eureka" table lists ACCOUNTS, LOANS, CARDS.
2. `GET /api/fetchCustomerDetails?mobileNumber=4354437687` after creating the customer in all three services (direct ports in this section).
3. **Scale loans:** remove `container_name` from loans, then `docker compose up -d --scale loans=2`. Eureka shows two LOANS instances; accounts alternates between them (watch each container's logs).
4. **Kill loans:** `docker stop loans-ms`, call `fetchCustomerDetails`: it fails (500). Wait ~90 s (missed heartbeats): the instance disappears from Eureka.

## 5. Traps and senior notes
- **Eureka has a self-preservation mode**: if many heartbeats are missed at once (e.g. a network blip), it stops evicting instances, assuming the network is broken, not the
  services. You may see stale instances. That's by design.
- **Discovery data is eventually consistent.** After a service dies, callers may still try it for up to a minute or so.
- **Feign interfaces duplicate the remote API**, so version your APIs and keep them backward compatible.
- **Chapter 17 removes Eureka** entirely on Kubernetes, because the platform already does discovery. Know both models.
