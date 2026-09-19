# Chapter 20: The BOM and the common library (`section_20/`)

New in this section: **`eazy-bom`** (a parent POM) and its **`common`** module (a shared library). The services (`accounts`, `cards`, `loans`, `configserver`, `eurekaserver`, `gatewayserver`, `message`) are the section-14 versions refactored to use them.
Section 20 also contains the Eureka server again: it builds on section 14's design, not section 17's Kubernetes-native one.

## 1. The problem
Look at the seven `pom.xml` files in chapters 8–14. They all repeat the same things:
- the Spring Boot, Spring Cloud, Lombok, springdoc, OpenTelemetry versions (**7 places to update** for one upgrade, and drift is easy: one service on Boot 3.4 and another on 3.5);
- the same Java version, Jib plugin and image tag;
- identical *classes*: `ErrorResponseDto` is copy-pasted into `accounts`, `loans` and `cards`.

Copy-paste means a bug fix or a version bump must be repeated everywhere, and someone will forget one.

## 2. The idea: one place for versions, one place for shared code
**A BOM (Bill Of Materials)** is a `pom` that declares *versions* (via `<dependencyManagement>`) but doesn't make anyone use them. Projects that **inherit from it** can then say `<dependency>` **without a version**.
Because the version lives in **one file**, upgrading Spring Boot for the whole fleet is a one-line change.

```
eazy-bom (parent POM)          ← versions + shared build config
   ├── common (module)         ← shared code: ErrorResponseDto
   └── (children inherit)  accounts, loans, cards, gatewayserver, ...
```
Two Maven ideas people mix up:

| | `<parent>` (inheritance) | `<dependencyManagement>` `import` (BOM import) |
|---|---|---|
| What you get | Everything in the parent: properties, plugin config, dependency management | Only the version list |
| Limit | A project can have **one** parent | Can import many BOMs |

The `eazy-bom` is used as a **parent** (so children also inherit properties and the plugin config) *and* it internally **imports** Spring's own BOMs.

## 3. Code walkthrough

### 3.1 The parent: `section_20/eazy-bom/pom.xml`
```xml
1   <groupId>com.eazybytes</groupId>
2   <artifactId>eazy-bom</artifactId>
3   <version>0.0.1-SNAPSHOT</version>
4   <packaging>pom</packaging>
5   <properties>
6       <common-lib.version>1.0.0</common-lib.version>
7       <spring-boot.version>4.0.0</spring-boot.version>
8       <java.version>21</java.version>
9       <maven.compiler.source>21</maven.compiler.source>
10      <maven.compiler.target>21</maven.compiler.target>
11      <spring-cloud.version>2025.1.0</spring-cloud.version>
12      <spring-doc.version>2.8.14</spring-doc.version>
13      <h2.version>2.3.232</h2.version>
14      <lombok.version>1.18.42</lombok.version>
15      <otel.version>2.22.0</otel.version>
16      <micrometer.version>1.16.0</micrometer.version>
17      <jib.version>3.5.1</jib.version>
18      <image.tag>s20</image.tag>
19  </properties>
20  <modules>
21      <module>common</module>
22  </modules>
23  <dependencies>
24      <dependency>
25          <groupId>org.springframework.boot</groupId>
26          <artifactId>spring-boot-starter-test</artifactId>
27          <scope>test</scope>
28      </dependency>
29  </dependencies>
30  <dependencyManagement>
31      <dependencies>
32          <dependency> spring-boot-dependencies ${spring-boot.version} (type pom, scope import) </dependency>
33          <dependency> lombok ${lombok.version}                        (type pom, scope import) </dependency>
34          <dependency> h2 ${h2.version}                                (type pom, scope import) </dependency>
35          <dependency> springdoc-openapi-starter-webmvc-ui ${spring-doc.version} </dependency>
36          <dependency> spring-cloud-dependencies ${spring-cloud.version} (type pom, scope import) </dependency>
37      </dependencies>
38  </dependencyManagement>
39  <build>
40      <plugins>
41          <plugin>
42              <groupId>org.springframework.boot</groupId>
43              <artifactId>spring-boot-maven-plugin</artifactId>
44          </plugin>
45      </plugins>
46  </build>
```
- **Line 4, `<packaging>pom</packaging>`**: this project produces no jar; it only exists to be inherited from or aggregated.
- **Lines 5–19, `<properties>`**: **the single source of truth for versions.** Want Spring Boot 4.0.1? Change line 7 once. `image.tag` (line 18) is `s20`, so every service's image name (`eazybytes/${project.artifactId}:${image.tag}`) updates together.
- **Lines 20–22, `<modules>`**: this is also an *aggregator*: building `eazy-bom` builds `common` too.
- **Lines 23–29, `<dependencies>`** (not management): `spring-boot-starter-test` with scope `test` is added to **every child automatically** (all services need test support). Contrast with lines 30+, which only *manage* versions.
- **Lines 30–38, `<dependencyManagement>`**: **importing other BOMs**: `spring-boot-dependencies` and `spring-cloud-dependencies` (each `type pom` + `scope import` = "pull in that BOM's whole version list"), plus pinned versions for Lombok, H2 and springdoc.
  After this, a child can declare `spring-boot-starter-web` or `spring-cloud-starter-config` **with no `<version>`**: it's resolved from here.
- **Lines 39–46**: the Spring Boot Maven plugin configured once (creates the runnable fat jar).

### 3.2 The shared library: `eazy-bom/common`
`common/pom.xml`:
```xml
1  <parent>
2      <groupId>com.eazybytes</groupId>
3      <artifactId>eazy-bom</artifactId>
4      <version>0.0.1-SNAPSHOT</version>
5  </parent>
6  <groupId>com.eazybytes</groupId>
7  <artifactId>common</artifactId>
8  <version>${common-lib.version}</version>
9  <dependencies>
10     <dependency> spring-boot-starter-webmvc </dependency>
11     <dependency> lombok (optional=true, ${lombok.version}) </dependency>
12     <dependency> springdoc-openapi-starter-webmvc-ui (${spring-doc.version}) </dependency>
13 </dependencies>
```
- **Lines 1–5**: `common` **inherits** from `eazy-bom`; it's a child like the services.
- **Line 8, `<version>${common-lib.version}</version>`**: the library's version comes from the parent's property (`1.0.0`, line 6 above). Services depend on it with the same property, so they can never disagree.
- **Line 11, `optional`**: Lombok is needed to *compile* the library but shouldn't be forced onto every consumer (`optional=true` keeps it from being passed on transitively).
- **Lines 10 and 12**: the library needs the web starter and the OpenAPI annotations for the `@Schema` on its DTO.

`common/src/main/java/com/eazybytes/common/dto/ErrorResponseDto.java`, the class formerly copied three times:
```java
1  package com.eazybytes.common.dto;
2  @Data @AllArgsConstructor
3  @Schema(
4          name = "ErrorResponse",
5          description = "Schema to hold error response information"
6  )
7  public class ErrorResponseDto {
8      @Schema(description = "API path invoked by client")
9      private  String apiPath;
10     @Schema(description = "Error code representing the error happened")
11     private HttpStatus errorCode;
12     @Schema(description = "Error message representing the error happened")
13     private  String errorMessage;
14     @Schema(description = "Time representing when the error happened")
15     private LocalDateTime errorTime;
16 }
```
- **Line 2**: `@Data` (getters/setters/equals/toString) and `@AllArgsConstructor` come from Lombok; the constructor is what `GlobalExceptionHandler` calls in chapter 2.
- **Lines 3–15**: `@Schema` annotations make the error shape appear in Swagger docs. **Line 11:** `HttpStatus` serialises as e.g. `"NOT_FOUND"` (which is why our earlier 404 said `"errorCode":"404 NOT_FOUND"`).

### 3.3 A service consumes both: `section_20/accounts/pom.xml`
```xml
5   <parent>
6       <groupId>com.eazybytes</groupId>
7       <artifactId>eazy-bom</artifactId>
8       <version>0.0.1-SNAPSHOT</version>
9       <relativePath>../eazy-bom/pom.xml</relativePath>
10  </parent>
11  <groupId>com.eazybytes</groupId>
12  <artifactId>accounts</artifactId>
13  <version>0.0.1-SNAPSHOT</version>
14  <packaging>jar</packaging>
...
19  <dependency>
20      <groupId>com.eazybytes</groupId>
21      <artifactId>common</artifactId>
22      <version>${common-lib.version}</version>
23  </dependency>
...
140 <plugin>
141     <groupId>com.google.cloud.tools</groupId>
142     <artifactId>jib-maven-plugin</artifactId>
143     <version>${jib.version}</version>
144     <configuration>
145         <to>
146             <image>eazybytes/${project.artifactId}:${image.tag}</image>
147         </to>
148     </configuration>
149 </plugin>
```
- **Lines 5–10**: **`<parent>`** points at the BOM, with **`relativePath`** so Maven finds it on disk (`../eazy-bom/pom.xml`) without needing it installed in a repository. (Compare chapter 14, where the parent was `spring-boot-starter-parent`.)
- **Lines 19–23**: the dependency on `common`, versioned with `${common-lib.version}` from the parent.
- **Lines 143 and 146**: the Jib plugin version and image tag are **variables** (`${jib.version}`, `${image.tag}`), where in `section_14` they were hard-coded `3.5.1` and `s14`.
- **Build order matters**: `common` must be built and installed first (`mvn install` inside `eazy-bom`), otherwise `accounts` can't resolve `com.eazybytes:common:1.0.0`.

And in the Java code, the local copy is deleted; the diff between `section_14` and `section_20` shows the `dto/ErrorResponseDto.java` file *removed* from accounts/loans/cards and the imports changed:
```diff
  // GlobalExceptionHandler.java, AccountsController.java, CustomerController.java
- import com.eazybytes.accounts.dto.ErrorResponseDto;
+ import com.eazybytes.common.dto.ErrorResponseDto;
```
Same class name, new package: the only code change in the services.

## 4. Try it
```bash
cd section_20/eazy-bom && mvn clean install                # builds and installs the parent + common
cd ../accounts && mvn clean compile jib:dockerBuild        # image  eazybytes/accounts:s20
mvn dependency:tree | grep common                          # shows com.eazybytes:common:jar:1.0.0
```
Experiment: change `<java.version>` or `<image.tag>` in `eazy-bom/pom.xml`, rebuild two services, and see both pick it up with no edits of their own.

## 5. Traps and senior notes
- **Shared libraries couple your services.** Once `common` is used by 7 services, changing `ErrorResponseDto` is a *breaking change for 7 teams*. Keep shared code tiny and stable (DTOs, error formats, maybe logging helpers). **Never put business logic in a shared library**:
  that's how you rebuild a monolith with extra steps.
- **Share *contracts*, not *classes*, across services.** Note the contrast: `AccountsMsgDto` and `LoansDto` are still duplicated per service on purpose, because each service should evolve its view of another service's API independently (Feign clients, Kafka payloads). `ErrorResponseDto` is safe to share because it's the *platform's* error format, not a domain object.
- **Versioning discipline:** `-SNAPSHOT` versions mean "may change under you". Real setups publish releases to an artifact repository (Nexus/Artifactory) and pin exact versions.
- **BOM vs parent:** a lightweight alternative is *only* importing the BOM (no inheritance) so projects keep their own parent. The course chooses inheritance because it also shares properties and the build plugin.
- **The trade-off in a sentence:** a BOM buys consistency and one-line upgrades; the price is that all services move together and must be built in the right order.
