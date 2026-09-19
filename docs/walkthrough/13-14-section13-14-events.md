# Chapters 13 and 14: Event-driven microservices (`section_13/` RabbitMQ, `section_14/` Kafka)

New in these sections: the **`message`** service, `AccountsFunctions` and the `StreamBridge` call in `accounts`, and a message broker container. Section 13 uses **RabbitMQ**; section 14 swaps in **Kafka**
with almost no code change, and that is the whole point of the design.

## 1. The problem
When an account is created we also want to email and text the customer. The naive design has `accounts` call the message service over HTTP (a Feign call like chapter 8):

```
POST /create ──► accounts ──HTTP──► message (email, sms) ──► back to accounts ──► 201
```
Problems:
- **Slow:** the customer waits while emails are "sent".
- **Fragile:** if the message service is down, *account creation fails*, even though the account itself was fine.
- **Tight coupling:** accounts must know about messaging, and every new "thing to do on account creation" (audit, analytics, fraud check) means editing accounts.

## 2. The idea: publish an event, don't call a service
Accounts says **"an account was created"** by putting a message on a **broker** and immediately returns 201. Anyone interested can consume it, whenever they're ready.

```
                                  ┌─ topic: send-communication ─┐
 accounts ──publish──►            │   {accountNumber, name,     │ ──consume──► message service
 (returns 201 immediately)        │    email, mobileNumber}     │              runs  email | sms
                                  └─────────────────────────────┘                      │
 accounts ◄──consume── topic: communication-sent  ◄─────────────publish──────────────┘
 (marks account "communication sent")                       (the account number)
```
| Term | Meaning |
|------|---------|
| **Broker** | The middleman that stores messages (RabbitMQ / Kafka) |
| **Topic / destination** | A named channel messages are published to |
| **Producer / consumer** | The sender / the receiver |
| **Consumer group** | Consumers sharing a group name **split** the messages (each message goes to *one* of them). Different groups each get *all* messages |
| **Asynchronous** | The sender doesn't wait for the receiver |

Benefits: **loose coupling**, **the sender survives a dead receiver** (messages wait in the broker), and easy fan-out to new consumers. Costs: **eventual consistency** (the "communication sent" flag flips a moment later),
harder debugging, and you must design for **duplicates** (most brokers deliver *at least once*).

**Two Spring libraries do the work:**
- **Spring Cloud Function**: write logic as plain Java `Function<In,Out>`, `Consumer<In>` or `Supplier<Out>` beans. No broker code.
- **Spring Cloud Stream**: *binds* those functions to a broker using configuration. Change the binder (RabbitMQ → Kafka) and your functions don't change.

## 3. Code walkthrough

### 3.1 The message payload (a Java `record`)
`AccountsMsgDto.java` (identical in `accounts` and `message`; each service has its own copy):
```java
1  package com.eazybytes.message.dto;
9  public record AccountsMsgDto(Long accountNumber, String name, String email, String mobileNumber) {
10 }
```
- **Line 9**: a `record` is an immutable data holder with an automatic constructor and getters (`accountNumber()`). It's serialised to JSON on the wire. I read the actual message from the broker:
  `{"accountNumber":1383311087,"name":"Madan Reddy","email":"tutor@eazybytes.com","mobileNumber":"4354437687"}`.
- The two services **don't share the class**, only the JSON *shape*. That's the contract; keep it backward-compatible.

### 3.2 The producer: `accounts`
`AccountsServiceImpl.java` (excerpt):
```java
1  @Service
2  @AllArgsConstructor
3  public class AccountsServiceImpl implements IAccountsService {
4      private final StreamBridge streamBridge;
     ...
8      public void createAccount(CustomerDto customerDto) {
9          Customer customer = CustomerMapper.mapToCustomer(customerDto, new Customer());
10         Optional<Customer> optionalCustomer = customerRepository.findByMobileNumber(customerDto.getMobileNumber());
11         if(optionalCustomer.isPresent()) {
12             throw new CustomerAlreadyExistsException("Customer already registered with given mobileNumber "
13                     +customerDto.getMobileNumber());
14         }
15         Customer savedCustomer = customerRepository.save(customer);
16         Accounts savedAccount = accountsRepository.save(createNewAccount(savedCustomer));
17         sendCommunication(savedAccount, savedCustomer);
18     }
19     private void sendCommunication(Accounts account, Customer customer) {
20         var accountsMsgDto = new AccountsMsgDto(account.getAccountNumber(), customer.getName(),
21                 customer.getEmail(), customer.getMobileNumber());
22         log.info("Sending Communication request for the details: {}", accountsMsgDto);
23         var result = streamBridge.send("sendCommunication-out-0", accountsMsgDto);
24         log.info("Is the Communication request successfully triggered ? : {}", result);
25     }
```
- **Line 4, `StreamBridge`**: the tool for publishing **from ordinary code** (like a REST handler). Function beans are triggered *by* messages; `StreamBridge` lets *you* trigger sending.
- **Lines 15–16**: same save logic as chapter 2. **Line 17**: after the DB writes, publish the event.
- **Line 23, `streamBridge.send("sendCommunication-out-0", dto)`**: the first argument is a **binding name**, not a topic. The topic is defined in configuration (3.5). Spring converts the record to JSON.
- **Line 24**: `send` returns a `boolean` (true if handed to the binder). It does **not** mean the consumer processed it.
- **Design trap (the "dual write" problem):** lines 15–16 write to the database, line 23 writes to the broker. These are **two systems with no shared transaction**. If the app crashes between them, the account exists but no event is ever sent.
  Production fixes: the **transactional outbox** pattern (write the event to a DB table in the same transaction, then relay it) or CDC tools like Debezium.

### 3.3 The consumer of the result: `accounts`
`AccountsFunctions.java`:
```java
2  @Configuration
3  public class AccountsFunctions {
5      private static final Logger log = LoggerFactory.getLogger(AccountsFunctions.class);
7      @Bean
8      public Consumer<Long> updateCommunication(IAccountsService accountsService) {
9          return accountNumber -> {
10             log.info("Updating Communication status for the account number : " + accountNumber.toString());
11             accountsService.updateCommunicationStatus(accountNumber);
12         };
13     }
14 }
```
- **Line 2, `@Configuration`** + **Line 7, `@Bean`**: a function is just a bean. Its **bean name (`updateCommunication`) is its identity** for the configuration in 3.5.
- **Line 8, `Consumer<Long>`**: takes one value and returns nothing; it's an *input-only* endpoint. Its input is the account number published on `communication-sent`.
- **Line 8, parameter `IAccountsService accountsService`**: Spring **injects a dependency into the `@Bean` method**, an easy way to give the function access to your service.
- **Line 11**: calls the service method:
```java
public boolean updateCommunicationStatus(Long accountNumber) {
    boolean isUpdated = false;
    if(accountNumber !=null ){
        Accounts accounts = accountsRepository.findById(accountNumber).orElseThrow(
                () -> new ResourceNotFoundException("Account", "AccountNumber", accountNumber.toString()));
        accounts.setCommunicationSw(true);
        accountsRepository.save(accounts);
        isUpdated = true;
    }
    return isUpdated;
}
```
  It loads the account and sets `communicationSw = true` (a `Boolean` column on `Accounts`). This closes the loop: *"the customer was notified"*.

### 3.4 The consumer/processor: the `message` service
`MessageFunctions.java`:
```java
1  package com.eazybytes.message.functions;
4  @Configuration
5  public class MessageFunctions {
6      private static final Logger log = LoggerFactory.getLogger(MessageFunctions.class);
8      @Bean
9      public Function<AccountsMsgDto,AccountsMsgDto> email() {
10         return accountsMsgDto -> {
11             log.info("Sending email with the details : " +  accountsMsgDto.toString());
12             return accountsMsgDto;
13         };
14     }
16     @Bean
17     public Function<AccountsMsgDto,Long> sms() {
18         return accountsMsgDto -> {
19             log.info("Sending sms with the details : " +  accountsMsgDto.toString());
20             return accountsMsgDto.accountNumber();
21         };
22     }
23 }
```
- **Lines 9–14, `email()`** is a `Function<AccountsMsgDto,AccountsMsgDto>`: message in, message out. It only *logs* (a stand-in for a real mail API) and passes the message through unchanged.
- **Lines 17–22, `sms()`** is a `Function<AccountsMsgDto,Long>`: message in, **account number out**. That output is what accounts' `updateCommunication` expects.
- **They compose!** In configuration we write `email|sms`, and Spring Cloud Function chains them into **one function**: `email` runs first and its output feeds `sms`. The composed function's input is an `AccountsMsgDto`; its final output is the `Long`.
  This is the elegant bit: two tiny, independently testable functions, wired in YAML.

### 3.5 Configuration ties it all together
**`accounts/src/main/resources/application.yml`** (Kafka version, section 14):
```yaml
1  spring:
2    cloud:
3      function:
4        definition: updateCommunication
5      stream:
6        bindings:
7          updateCommunication-in-0:
8            destination: communication-sent
9            group: ${spring.application.name}
10         sendCommunication-out-0:
11           destination: send-communication
12       kafka:
13         binder:
14           brokers:
15             - localhost:9092
```
- **Lines 3–4, `function.definition`**: **which function beans to activate** as message handlers. Only `updateCommunication` (a consumer). Without this line Spring Cloud Function can't decide and may not bind anything.
- **Line 7, the naming rule:** a binding for a function is called **`<functionName>-in-<index>`** (input) or **`<functionName>-out-<index>`** (output). Index `0` is the first argument/result. So `updateCommunication-in-0` is the *input* of the
  function `updateCommunication`.
- **Line 8, `destination`**: the actual topic. **Line 9, `group: accounts`**: the consumer group. With a group, offsets are stored and the app **resumes where it left off** after a restart, and if you run 3 accounts instances they **share** the messages instead of each processing every one. Without a group,
  each instance gets its own anonymous group and *all* of them would process every message, with no memory across restarts.
- **Lines 10–11, `sendCommunication-out-0`**: an **output binding with no function behind it**. It exists only so `StreamBridge.send("sendCommunication-out-0", …)` (3.2, line 23) has a destination: `send-communication`.
  That's the link between code and topic.
- **Lines 12–15**: the Kafka **binder** settings: broker address. In Docker Compose it's overridden by `SPRING_CLOUD_STREAM_KAFKA_BINDER_BROKERS: "kafka:9092"`.

**`message/src/main/resources/application.yml`:**
```yaml
1  server:
2    port: 9010
4  spring:
5    application:
6      name: "message"
7    cloud:
8      function:
9        definition: email|sms
10     stream:
11       bindings:
12         emailsms-in-0:
13           destination: send-communication
14           group: ${spring.application.name}
15         emailsms-out-0:
16           destination: communication-sent
17       kafka:
18         binder:
19           brokers:
20             - localhost:9092
```
- **Line 9, `email|sms`**: the `|` composes the two beans. **Lines 12 and 15: the composed function is named `emailsms`** (the pipe is dropped from the binding name), giving `emailsms-in-0` and `emailsms-out-0`. **Getting this name wrong is the #1 bug here:** the app starts fine and simply never receives anything.
- **Line 13**: input from `send-communication` (what accounts publishes). **Line 16**: output to `communication-sent` (what accounts consumes). **The two services never mention each other:** they only agree on two topic names and one JSON shape.
- Note **`message` has no `spring.config.import`, no Eureka, no database and no controller.** It doesn't need to be *found* (nobody calls it) and it has no state. A pure message processor. That's why it's the simplest service here.

### 3.6 Section 13 (RabbitMQ) vs section 14 (Kafka): the actual diff
I diffed the two sections' `application.yml` files. The **only** difference is the broker block:
```yaml
# section_13  (RabbitMQ)                      # section_14  (Kafka)
  rabbitmq:                                       kafka:
    host: localhost                                 binder:
    port: 5672                                        brokers:
    username: guest                                     - localhost:9092
    password: guest
    connection-timeout: 10s
```
plus the `pom.xml` dependency (`spring-cloud-stream-binder-rabbit` → `spring-boot-starter-kafka` + `spring-cloud-stream-binder-kafka`) and the compose file (RabbitMQ container → Kafka container).
**Not one line of Java changed.** All the `Function`, `Consumer` and `StreamBridge` code is identical.

### 3.7 The Kafka container (`section_14/docker-compose/default/docker-compose.yml`)
```yaml
1  kafka:
2    image: apache/kafka:4.1.1
3    hostname: kafka
4    container_name: kafka
5    ports:
6      - "9092:9092"
7    environment:
8      KAFKA_BROKER_ID: 1
9      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT,CONTROLLER:PLAINTEXT
10     KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:29092,PLAINTEXT_HOST://kafka:9092
11     KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
15     KAFKA_PROCESS_ROLES: broker,controller
16     KAFKA_NODE_ID: 1
17     KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:29093
18     KAFKA_LISTENERS: PLAINTEXT://kafka:29092,CONTROLLER://kafka:29093,PLAINTEXT_HOST://kafka:9092
19     KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
20     KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
21     KAFKA_LOG_DIRS: /tmp/kraft-combined-logs
22     CLUSTER_ID: MkU3OEVBNTcwNTJENDM2Qk
23   healthcheck:
24     test: [ "CMD-SHELL", "nc -z kafka 9092 || exit 1" ]
```
- **Line 15, `broker,controller`** = **KRaft mode**: this single node is both the data broker and the cluster's metadata controller. **No ZooKeeper** needed (older Kafka required a separate ZooKeeper cluster).
- **Lines 9–10 and 18, listeners**: a Kafka broker has several "listeners" (address + protocol). `PLAINTEXT://kafka:29092` is for broker-internal traffic, `PLAINTEXT_HOST://kafka:9092` is what clients in the Docker network use (and what we published to your host on port 9092),
  `CONTROLLER://kafka:29093` is the metadata channel. **The address a broker *advertises* (line 10) is what clients reconnect to after the first handshake.** If it's not resolvable from the client, you get "connected, then timed out" errors. That's the classic Kafka-in-Docker trap.
- **Lines 8, 11, 16:** a single node, so every replication factor is **1** (no redundancy); production uses ≥3 brokers with replication 3.
- **Line 24**: readiness check: port 9092 accepts connections. Other services `depends_on: kafka: condition: service_healthy`.

## 4. Try it and break it (verified on the running stack)
Create an account through the gateway (with a token from chapter 12), then watch each hop:
```bash
docker logs message-ms  | grep "Sending"       # Sending email with the details : AccountsMsgDto[accountNumber=1383311087, ...]
                                              # Sending sms   with the details : AccountsMsgDto[...]
docker logs accounts-ms | grep Communication  # Is the Communication request successfully triggered ? : true
                                              # Updating Communication status for the account number : 1383311087
```
Then look at the broker itself. (On Windows Git Bash prefix with `MSYS_NO_PATHCONV=1` so `/opt/...` isn't rewritten.)
```bash
docker exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 --list
#  __consumer_offsets   communication-sent   send-communication
docker exec kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka:29092 --describe --group message
#  GROUP=message  TOPIC=send-communication  PARTITION=0  CURRENT-OFFSET=2  LOG-END-OFFSET=2  LAG=0
docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:29092 --topic send-communication --from-beginning --timeout-ms 4000
#  {"accountNumber":1383311087,"name":"Madan Reddy","email":"tutor@eazybytes.com","mobileNumber":"4354437687"}
docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh ... --topic communication-sent --from-beginning --timeout-ms 4000
#  1383311087
```
What that output shows: **two topics** created automatically (`send-communication`, `communication-sent`), **two consumer groups** (`message`, `accounts`), and **LAG = 0** (every published message was consumed: the healthy state). *LAG = end offset − consumer's offset; a growing lag means the consumer is falling behind.*

Break it on purpose:
1. `docker stop message-ms`, create an account: **201 is still returned instantly**. `docker start message-ms` and watch it process the backlog: the whole benefit of asynchrony. (Compare with a synchronous design where step 1 would have failed.)
   **I ran exactly this.** Consumer group `message` before: `LAG=0 (offset 2/2)`. With `message-ms` stopped and one account created: HTTP **201**, and `LAG=1 (offset 2/3)`: the event was waiting safely in Kafka. After `docker start message-ms`:
   `LAG=0 (offset 3/3)` and its log contained the "Sending email/sms" lines for the account created *while it was down*.
2. `docker stop kafka` then create an account: the account is saved, but `StreamBridge.send` fails or times out and, depending on settings, may fail the request. This shows the dual-write risk from 3.2.
3. In `message`'s YAML, change `emailsms-in-0` to `email-in-0` and restart: it starts cleanly but **receives nothing**. Names must match.

## 5. Traps and senior notes
- **Idempotent consumers.** Delivery is at-least-once, so a redelivered message must not cause harm. `updateCommunicationStatus` is naturally idempotent (setting a flag to true twice is the same as once). Sending an email twice is not, so real systems deduplicate by message id.
- **Poison messages.** If a message always throws, the consumer retries and may loop forever. Configure retries + a **dead-letter topic** (DLQ).
- **Ordering and partitions.** Kafka keeps order only **within a partition**. One partition is why everything here is strictly ordered; with several partitions you choose a *key* (e.g. account number) to keep related events together.
- **Kafka vs RabbitMQ in one line:** RabbitMQ is a smart broker that routes and *deletes* messages once consumed; Kafka is a durable, replayable **log** that consumers read at their own pace. Pick RabbitMQ for task queues and flexible routing, Kafka for event streams, replay and high throughput.
- **Schema evolution.** Adding a field to `AccountsMsgDto` is safe; renaming or removing one breaks consumers. Consider a schema registry (Avro/Protobuf) for larger systems.
