# Chapter 2: Building a Spring Boot microservice (`section2/`)

Folder: `section2/accounts` (loans and cards are built the same way). We follow **one request**, `POST /api/create`,
from the HTTP call down to the database and back.

## 1. The problem
We need a bank backend. Before splitting anything, we must build **one well-structured service**. If this one is messy,
three messy services are worse than a messy monolith.

## 2. The idea: layers, each with one job

```
HTTP request
   │
   ▼
Controller   → speaks HTTP: parse JSON, validate, choose status code.  NO business rules.
   │
   ▼
Service      → business rules: "a mobile number can't register twice".  NO HTTP, NO SQL.
   │
   ▼
Repository   → talks to the database. NO business rules.
   │
   ▼
Database (H2)
```

Rule of thumb: **each layer only knows the layer below it.** That's what lets you change one without breaking the others.
Between layers, data travels as **DTOs** (API shape) and **Entities** (database shape), with **Mappers** converting between them.

## 3. Code walkthrough

### 3.1 The entry point: `AccountsApplication.java`
```java
1  package com.eazybytes.accounts;
2  @SpringBootApplication
3  /*@ComponentScans({ @ComponentScan("com.eazybytes.accounts.controller") })
4  @EnableJpaRepositories("com.eazybytes.accounts.repository")
5  @EntityScan("com.eazybytes.accounts.model")*/
6  @EnableJpaAuditing(auditorAwareRef = "auditAwareImpl")
7  @OpenAPIDefinition( info = @Info( title = "Accounts microservice REST API Documentation", ... ) )
27 public class AccountsApplication {
28 	public static void main(String[] args) {
29 		SpringApplication.run(AccountsApplication.class, args);
30 	}
31 }
```
- **Line 2, `@SpringBootApplication`**: three annotations in one: `@Configuration` (this class can define beans),
  `@EnableAutoConfiguration` (look at the classpath and set things up: web server, JPA, …) and `@ComponentScan`
  (find every `@Service`, `@RestController`, … **in this package and below**).
- **Lines 3–5** (commented out): the manual version of what `@ComponentScan` does. It's only there to show that you'd
  need these if your classes lived *outside* the main package. **Junior trap:** put a class in a sibling package like
  `com.other.Foo` and Spring will never find it.
- **Line 6, `@EnableJpaAuditing`**: switches on automatic `createdAt/updatedAt/createdBy/updatedBy` filling. `auditorAwareRef`
  names the bean that answers "who is the current user?" (see 3.4).
- **Line 7, `@OpenAPIDefinition`**: metadata for the auto-generated Swagger docs at `/swagger-ui/index.html`.
- **Lines 28–30**: `main` starts Spring, which starts the embedded Tomcat on the port from `application.yml`. There is no
  external server to install.

### 3.2 The configuration: `application.yml`
```yaml
1  server:
2    port: 8080
3  spring:
4    datasource:
5      url: jdbc:h2:mem:testdb
6      driverClassName: org.h2.Driver
7      username: sa
8      password: ''
9    h2:
10     console:
11       enabled: true
12   jpa:
13     database-platform: org.hibernate.dialect.H2Dialect
14     hibernate:
15       ddl-auto: update
16     show-sql: true
```
- **Line 2**: the service listens on 8080. Loans uses 8090 and cards 9000 so all three can run on one laptop.
- **Line 5**: `jdbc:h2:mem:testdb` means an **in-memory** H2 database. It lives inside the JVM and **disappears on restart**.
  Perfect for learning, never for production. (Chapter 7 replaces it with MySQL.)
- **Lines 9–11**: exposes H2's web console at `/h2-console` so you can look at the tables.
- **Line 15, `ddl-auto: update`**: Hibernate compares your entities with the DB and adds missing tables/columns. Handy in dev; in
  production teams use migration tools (Flyway/Liquibase) instead, because "update" can't be reviewed or rolled back.
- **Line 16**: prints every SQL statement in the log. You'll use this constantly to see what JPA is *really* doing.

There's also `src/main/resources/schema.sql`. Spring Boot runs it automatically for embedded databases. It creates the
`customer` and `accounts` tables (with audit columns) before Hibernate's `update` reconciles them.

### 3.3 Entities: the database shape

`BaseEntity.java`, the audit columns every table shares:
```java
2  @MappedSuperclass
3  @EntityListeners(AuditingEntityListener.class)
4  @Getter @Setter @ToString
5  public class BaseEntity {
6      @CreatedDate
7      @Column(updatable = false)
8      private LocalDateTime createdAt;
9      @CreatedBy
10     @Column(updatable = false)
11     private String createdBy;
12     @LastModifiedDate
13     @Column(insertable = false)
14     private LocalDateTime updatedAt;
15     @LastModifiedBy
16     @Column(insertable = false)
17     private String updatedBy;
18 }
```
- **Line 2, `@MappedSuperclass`**: "this class has no table of its own; its fields become columns in every subclass's table."
  That is how `Customer` and `Accounts` share audit columns without repeating them.
- **Line 3**: hooks the entity into Spring's auditing. Before insert/update, the listener fills the annotated fields.
- **Lines 6–8**: `@CreatedDate` is set on insert. `updatable = false` guarantees nobody overwrites it later.
- **Lines 12–14**: `@LastModifiedDate` is set on update. `insertable = false` keeps it null on the first insert.
- **Line 4, Lombok** (`@Getter @Setter @ToString`): generates the boilerplate at compile time so the file stays tiny.

`Customer.java`:
```java
2  @Entity
3  @Getter @Setter @ToString @AllArgsConstructor @NoArgsConstructor
4  public class Customer extends  BaseEntity {
5      @Id
6      @GeneratedValue(strategy = GenerationType.IDENTITY)
7      @Column(name="customer_id")
8      private Long customerId;
9      private String name;
10     private String email;
11     @Column(name="mobile_number")
12     private String mobileNumber;
13 }
```
- **Line 2, `@Entity`**: maps this class to a table named `customer`.
- **Lines 5–8**: primary key. `IDENTITY` delegates numbering to the DB (auto-increment).
- **Line 11**: Java is `mobileNumber`, DB column is `mobile_number`. Explicit `@Column` avoids relying on naming-strategy magic.
- **Line 4**: `extends BaseEntity` brings in the four audit columns. `@NoArgsConstructor` is required by JPA, which builds
  objects by reflection.

`Accounts.java` is similar, with two differences worth noticing:
```java
5  @Column(name="customer_id")
6  private Long customerId;
7  @Column(name="account_number")
8  @Id
9  private Long accountNumber;
```
- `customerId` is a **plain number**, not a `@ManyToOne Customer`. It's a deliberate, simple design: a foreign key by value.
- The primary key `accountNumber` has **no `@GeneratedValue`**, so *we* must assign it. The service does that (see 3.6).

### 3.4 Repositories: the database access layer
```java
// CustomerRepository
2  @Repository
3  public interface CustomerRepository extends JpaRepository<Customer, Long> {
4      Optional<Customer> findByMobileNumber(String mobileNumber);
5  }

// AccountsRepository
2  @Repository
3  public interface AccountsRepository extends JpaRepository<Accounts, Long> {
4      Optional<Accounts> findByCustomerId(Long customerId);
5      @Transactional
6      @Modifying
7      void deleteByCustomerId(Long customerId);
8  }
```
- **They are interfaces, and you write no implementation.** Spring Data generates the class at startup.
- **`extends JpaRepository<Customer, Long>`** ("entity type, id type") gives you `save`, `findById`, `findAll`, `deleteById`… for free.
- **`findByMobileNumber`**: Spring Data **parses the method name** (`findBy` + field `MobileNumber`) and writes the SQL
  `select … where mobile_number = ?`. Misspell the field and the app **fails at startup**, which is good.
- **`Optional<…>`**: "might not exist". It forces the caller to handle "not found" instead of hitting a `NullPointerException`.
- **Lines 5–7**: derived delete methods that modify data need `@Transactional` (a database transaction) and `@Modifying`.

The auditor bean, `AuditAwareImpl.java`:
```java
2  @Component("auditAwareImpl")
3  public class AuditAwareImpl implements AuditorAware<String> {
9      @Override
10     public Optional<String> getCurrentAuditor() {
11         return Optional.of("ACCOUNTS_MS");
12     }
13 }
```
- **Line 2**: the bean name `"auditAwareImpl"` matches `auditorAwareRef = "auditAwareImpl"` in the main class. That's the link.
- **Line 11**: hard-coded to `"ACCOUNTS_MS"` because there's no logged-in user yet. Once security exists (chapter 12) you'd return the user
  from the JWT.

### 3.5 DTOs and validation: the API contract
`CustomerDto.java` (Swagger `@Schema` annotations removed):
```java
2  @Data
7  public class CustomerDto {
11     @NotEmpty(message = "Name can not be a null or empty")
12     @Size(min = 5, max = 30, message = "The length of the customer name should be between 5 and 30")
13     private String name;
17     @NotEmpty(message = "Email address can not be a null or empty")
18     @Email(message = "Email address should be a valid value")
19     private String email;
23     @Pattern(regexp = "(^$|[0-9]{10})", message = "Mobile number must be 10 digits")
24     private String mobileNumber;
28     private AccountsDto accountsDto;
29 }
```
- **Why a DTO instead of returning `Customer`?** The entity has audit columns and internal ids that are none of the client's business, and if
  you rename a column you'd silently break every client. The DTO is a **stable public contract**.
- **Lines 11–12**: `name` must be present and 5–30 characters. **Line 18**: must look like an email. **Line 23**: exactly 10 digits
  (`(^$|…)` also allows an empty string; a slightly odd choice you may want to tighten in real code).
- **Line 28**: the customer DTO **nests** the account DTO, so one JSON document represents "customer with account".

`CustomerMapper.java`:
```java
3  public static CustomerDto mapToCustomerDto(Customer customer, CustomerDto customerDto) {
4      customerDto.setName(customer.getName());
5      customerDto.setEmail(customer.getEmail());
6      customerDto.setMobileNumber(customer.getMobileNumber());
7      return customerDto;
8  }
9  public static Customer mapToCustomer(CustomerDto customerDto, Customer customer) {
10     customer.setName(customerDto.getName());
11     customer.setEmail(customerDto.getEmail());
12     customer.setMobileNumber(customerDto.getMobileNumber());
13     return customer;
14 }
```
Hand-written and explicit, so you can see the copying. It takes the target object as a parameter, which makes the same method reusable for
"create new" and "update existing". Libraries like **MapStruct** generate this for you; for three fields, hand-written is clearer.

### 3.6 The service: where the business rules live
`AccountsServiceImpl.createAccount`:
```java
2  @Service
3  @AllArgsConstructor
4  public class AccountsServiceImpl  implements IAccountsService {
5      private AccountsRepository accountsRepository;
6      private CustomerRepository customerRepository;
7      @Override
8      public void createAccount(CustomerDto customerDto) {
9          Customer customer = CustomerMapper.mapToCustomer(customerDto, new Customer());
10         Optional<Customer> optionalCustomer = customerRepository.findByMobileNumber(customerDto.getMobileNumber());
11         if(optionalCustomer.isPresent()) {
12             throw new CustomerAlreadyExistsException("Customer already registered with given mobileNumber "
13                     +customerDto.getMobileNumber());
14         }
15         Customer savedCustomer = customerRepository.save(customer);
16         accountsRepository.save(createNewAccount(savedCustomer));
17     }
18     private Accounts createNewAccount(Customer customer) {
19         Accounts newAccount = new Accounts();
20         newAccount.setCustomerId(customer.getCustomerId());
21         long randomAccNumber = 1000000000L + new Random().nextInt(900000000);
22         newAccount.setAccountNumber(randomAccNumber);
23         newAccount.setAccountType(AccountsConstants.SAVINGS);
24         newAccount.setBranchAddress(AccountsConstants.ADDRESS);
25         return newAccount;
26     }
```
- **Line 3, `@AllArgsConstructor`**: Lombok writes a constructor taking both repositories, and Spring uses it to **inject** them
  (constructor injection, the recommended style: dependencies are explicit and can't be forgotten).
- **Line 4**: `implements IAccountsService`: the controller depends on the interface, not this class, so tests can substitute a fake.
- **Line 9**: DTO → new entity.
- **Lines 10–14**: **the business rule**: one customer per mobile number. If it's taken, throw. The exception is translated to a clean HTTP 400 later (3.8).
- **Line 15**: `save` inserts the customer, and because of `IDENTITY`, the returned object now has its generated `customerId`.
- **Line 16**: creates and saves the linked account.
- **Line 21**: a random 10-digit account number. **Senior note:** random numbers can collide (a duplicate primary key → 500).
  Real systems use a sequence or a checksum-based generator. It's fine here because it's a teaching app.

`fetchAccount` shows the read pattern:
```java
28 public CustomerDto fetchAccount(String mobileNumber) {
29     Customer customer = customerRepository.findByMobileNumber(mobileNumber).orElseThrow(
30             () -> new ResourceNotFoundException("Customer", "mobileNumber", mobileNumber)
31     );
32     Accounts accounts = accountsRepository.findByCustomerId(customer.getCustomerId()).orElseThrow(
33             () -> new ResourceNotFoundException("Account", "customerId", customer.getCustomerId().toString())
34     );
35     CustomerDto customerDto = CustomerMapper.mapToCustomerDto(customer, new CustomerDto());
36     customerDto.setAccountsDto(AccountsMapper.mapToAccountsDto(accounts, new AccountsDto()));
37     return customerDto;
38 }
```
- **Lines 29–31**: `orElseThrow(() -> …)` unwraps the `Optional` or throws our own "not found" exception. No `null` checks anywhere.
- **Lines 32–34**: a customer without an account is a data problem, so it also throws.
- **Lines 35–36**: build the DTO from two entities. Two queries, two objects, one response.

`updateAccount` finds the account by its **account number**, updates it, then follows `customerId` to update the customer too.
`deleteAccount` deletes the account **first**, then the customer, because the account refers to the customer. Delete in the wrong order and a real
database with foreign keys would refuse.

### 3.7 The controller: HTTP only
```java
2  @RestController
3  @RequestMapping(path="/api", produces = {MediaType.APPLICATION_JSON_VALUE})
4  @AllArgsConstructor
5  @Validated
6  public class AccountsController {
7      private IAccountsService iAccountsService;
11     @PostMapping("/create")
12     public ResponseEntity<ResponseDto> createAccount(@Valid @RequestBody CustomerDto customerDto) {
13         iAccountsService.createAccount(customerDto);
14         return ResponseEntity
15                 .status(HttpStatus.CREATED)
16                 .body(new ResponseDto(AccountsConstants.STATUS_201, AccountsConstants.MESSAGE_201));
17     }
21     @GetMapping("/fetch")
22     public ResponseEntity<CustomerDto> fetchAccountDetails(@RequestParam
23              @Pattern(regexp="(^$|[0-9]{10})",message = "Mobile number must be 10 digits") String mobileNumber) {
25         CustomerDto customerDto = iAccountsService.fetchAccount(mobileNumber);
26         return ResponseEntity.status(HttpStatus.OK).body(customerDto);
27     }
```
- **Line 2, `@RestController`**: every method's return value is written straight into the HTTP response as JSON (no HTML views).
- **Line 3**: all routes start with `/api`. `produces` promises JSON.
- **Line 5, `@Validated`**: needed so constraints on **method parameters** (like the `@Pattern` on line 23) are checked.
- **Line 12**: `@RequestBody` turns the JSON into a `CustomerDto`. `@Valid` runs the `@NotEmpty/@Email/…` rules from 3.5 **before your code runs**. If any
  fail, Spring throws `MethodArgumentNotValidException`, and the global handler (3.8) returns a 400.
- **Lines 14–16**: `201 Created` (not 200) is the correct status for "a new thing now exists".
- **Line 22**: `@RequestParam` reads `?mobileNumber=…` from the URL.
- **Update returns 200 or 417** (`EXPECTATION_FAILED`) when nothing was updated; delete works the same way.
- The controller has **no `if` about business rules**: it only translates HTTP ↔ service calls.

### 3.8 One place for errors: `GlobalExceptionHandler`
```java
2  @ControllerAdvice
3  public class GlobalExceptionHandler  extends ResponseEntityExceptionHandler {
4      @Override
5      protected ResponseEntity<Object> handleMethodArgumentNotValid(...) {
7          Map<String, String> validationErrors = new HashMap<>();
8          List<ObjectError> validationErrorList = ex.getBindingResult().getAllErrors();
9          validationErrorList.forEach((error) -> {
10             String fieldName = ((FieldError) error).getField();
11             String validationMsg = error.getDefaultMessage();
12             validationErrors.put(fieldName, validationMsg);
13         });
14         return new ResponseEntity<>(validationErrors, HttpStatus.BAD_REQUEST);
15     }
16     @ExceptionHandler(Exception.class)
17     public ResponseEntity<ErrorResponseDto> handleGlobalException(Exception exception, WebRequest webRequest) {
19         ErrorResponseDto errorResponseDTO = new ErrorResponseDto(
20                 webRequest.getDescription(false), HttpStatus.INTERNAL_SERVER_ERROR,
22                 exception.getMessage(), LocalDateTime.now());
25         return new ResponseEntity<>(errorResponseDTO, HttpStatus.INTERNAL_SERVER_ERROR);
26     }
27     @ExceptionHandler(ResourceNotFoundException.class)  // → 404
38     @ExceptionHandler(CustomerAlreadyExistsException.class)  // → 400
```
- **Line 2, `@ControllerAdvice`**: "applies to every controller": one central place instead of `try/catch` in each method.
- **Lines 5–15**: when validation fails, turn each failed field into `{"name": "The length …"}`. The client sees exactly which field is wrong.
- **Line 16, the catch-all** (`Exception.class`) comes *last in priority*: Spring picks the **most specific** handler that matches, so
  `ResourceNotFoundException` (line 27) gets its 404 and only unexpected errors fall through to the 500.
- **Line 25**: never leak stack traces. The client gets a small, uniform `ErrorResponseDto` (path, status, message, time).

## 4. Try it and break it
```bash
cd section2/accounts && mvn spring-boot:run
# Swagger UI:  http://localhost:8080/swagger-ui/index.html
curl -X POST localhost:8080/api/create -H 'Content-Type: application/json' \
  -d '{"name":"Madan Reddy","email":"tutor@eazybytes.com","mobileNumber":"4354437687"}'    # 201
curl -X POST localhost:8080/api/create -H 'Content-Type: application/json' -d '{"name":"Ab"}'  # 400, lists each bad field
curl "localhost:8080/api/fetch?mobileNumber=1111111111"                                        # 404 with our error JSON
```
Post the same customer twice and watch the second call return 400 "already registered". Then open `/h2-console` (JDBC URL `jdbc:h2:mem:testdb`, user `sa`, empty password) and
look at the `customer` and `accounts` tables. Watch the SQL in the console (`show-sql: true`).

## 5. Traps and senior notes
- **Never expose entities.** Always DTOs.
- **Business rules belong in the service**, never the controller. The controller is glue.
- **`Optional.orElseThrow` beats null checks.** Exceptions + one global handler keep the happy path readable.
- **In-memory DB = amnesia.** If "my data disappeared" happens, that's why.
- **Loans and cards are copies of this pattern** (`loanNumber` / `cardNumber` are 12 digits instead). Read accounts well, and you've read all three.
