# Chapter 7: A real database per service (`section7/`)

## 1. The problem
H2 in memory forgets everything on restart, and it isn't what you run in production. We need a **real database**, and, the important microservices principle,
**each service must own its own database**.

## 2. The idea: database per service
```
accounts ──► accountsdb (MySQL)     loans ──► loansdb (MySQL)     cards ──► cardsdb (MySQL)
```
Why not one shared database? If two services read each other's tables, then changing a column breaks both, and they can no longer be deployed or scaled
independently: you've built a **distributed monolith**. If accounts needs loan data, it must ask the **loans service** (that's what the Feign call in chapter 8 does), never the
loans tables.

The cost: no cross-service SQL joins or single ACID transaction. Data consistency between services is handled with APIs and events (chapters 8, 13, 14).

## 3. Code walkthrough

### 3.1 The service configuration changes
`section7/accounts/src/main/resources/application.yml`:
```yaml
3  spring:
4    application:
5      name: "accounts"
6    profiles:
7      active: "prod"
8    datasource:
9      url: jdbc:mysql://localhost:3306/accountsdb
10     username: root
11     password: root
12   jpa:
13     show-sql: true
14   sql:
15     init:
16       mode: always
17   config:
18     import: "optional:configserver:http://localhost:8071/"
```
- **Line 9**: a MySQL JDBC URL: `host:port/database`. Compare with `jdbc:h2:mem:testdb` in chapter 2.
- **Lines 10–11**: credentials. `root/root` is **for the demo only**.
- **Lines 14–16, `sql.init.mode: always`**: run `schema.sql` on every startup. For an embedded DB (H2), Boot did this automatically; for an external DB like MySQL you
  must ask explicitly. That's why the file appears here.
- Notice `ddl-auto: update` and the H2 lines are **gone**: the schema is now owned by `schema.sql`. In `pom.xml`, `com.h2database:h2` is replaced by
  `com.mysql:mysql-connector-j` (the JDBC driver).

`schema.sql` uses `CREATE TABLE IF NOT EXISTS`, so re-running it on each start doesn't fail or wipe data:
```sql
1  CREATE TABLE IF NOT EXISTS `customer` (
2    `customer_id` int AUTO_INCREMENT  PRIMARY KEY,
3    `name` varchar(100) NOT NULL,
4    `email` varchar(100) NOT NULL,
5    `mobile_number` varchar(20) NOT NULL,
6    `created_at` date NOT NULL,
7    `created_by` varchar(20) NOT NULL,
8    `updated_at` date DEFAULT NULL,
9    `updated_by` varchar(20) DEFAULT NULL
10 );
```
- Lines 6–9 are the audit columns from `BaseEntity` (chapter 2): `NOT NULL` on the *created* pair and nullable on the *updated* pair, mirroring
  `insertable = false` for the updated fields.
- The `Customer` entity still uses `GenerationType.IDENTITY`, which maps to MySQL's `AUTO_INCREMENT` (line 2).

### 3.2 Compose: three MySQL containers and templates for them
`section7/docker-compose/default/common-config.yml`:
```yaml
6  microservice-db-config:
7    extends:
8      service: network-deploy-service
9    image: mysql
10   healthcheck:
11     test: [ "CMD", "mysqladmin" ,"ping", "-h", "localhost" ]
12     timeout: 10s
13     retries: 10
14     interval: 10s
15     start_period: 10s
16   environment:
17     MYSQL_ROOT_PASSWORD: root
...
27 microservice-configserver-config:
28   extends:
29     service: microservice-base-config
30   environment:
31     SPRING_PROFILES_ACTIVE: default
32     SPRING_CONFIG_IMPORT: configserver:http://configserver:8071/
33     SPRING_DATASOURCE_USERNAME: root
34     SPRING_DATASOURCE_PASSWORD: root
```
- **Line 9**: the official MySQL image. **Lines 10–15**: a health check; `mysqladmin ping` succeeds only when MySQL accepts connections.
  A container being *started* is not the same as the database being *ready*. This gap causes classic "connection refused at startup" bugs.
- **Line 17**: MySQL's image requires a root password from the environment.
- **Lines 33–34**: credentials are injected into *services* by environment variables (`SPRING_DATASOURCE_USERNAME` → `spring.datasource.username`), so the YAML values are
  only defaults.

`docker-compose.yml` (excerpt):
```yaml
2  accountsdb:
3    container_name: accountsdb
4    ports:
5      - 3306:3306
6    environment:
7      MYSQL_DATABASE: accountsdb
8    extends: {file: common-config.yml, service: microservice-db-config}
12 loansdb:
14   ports:
15     - 3307:3306
...
22 cardsdb:
24   ports:
25     - 3308:3306
...
47 accounts:
48   image: "eazybytes/accounts:s7"
...
52     environment:
53       SPRING_APPLICATION_NAME: "accounts"
54       SPRING_DATASOURCE_URL: "jdbc:mysql://accountsdb:3306/accountsdb"
...
56     depends_on:
57       accountsdb:
58         condition: service_healthy
```
- **Lines 5, 15, 25**: **three databases, three different host ports** (3306/3307/3308). They all listen on 3306 *inside* their containers; the host
  ports differ only so your laptop can connect to each one (e.g. with MySQL Workbench).
- **Line 7, `MYSQL_DATABASE`**: the MySQL image creates that database on first start.
- **Line 54**: inside the Docker network the URL uses the **container name** `accountsdb` and the **internal** port 3306, not `localhost:3307`.
  `localhost` inside a container means *that container itself*, a very common beginner mistake.
- **Lines 56–58**: the service waits for its DB to be *healthy* before starting.

## 4. Try it and break it
```bash
cd section7/docker-compose/default && docker compose up -d
docker exec -it accountsdb mysql -uroot -proot -e "use accountsdb; select * from customer;"
```
1. Create a customer, then `docker restart accounts-ms`: the customer is **still there** (contrast with H2).
2. `docker compose down` **removes the containers, and the data with them**, because there's no volume. Add `volumes:` to persist across `down`.
3. Point `accounts` at `loansdb` by mistake: it starts, but `schema.sql` creates accounts tables inside the loans database, a nice illustration of why boundaries need discipline.

## 5. Traps and senior notes
- **Persistence needs a volume.** A DB container without a mounted volume loses data when the container is deleted.
- **`sql.init.mode: always` + `IF NOT EXISTS`** is a stop-gap. Real projects use **Flyway/Liquibase**: versioned, reviewable, repeatable migrations.
- **`depends_on: service_healthy` protects startup only.** Your app should still retry connections if the DB restarts later.
- **Never ship `root/root`.** Use a dedicated user with least privilege and get the password from a secret.
