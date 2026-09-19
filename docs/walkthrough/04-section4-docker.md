# Chapter 4: Docker (`section4/`)

Folder: `section4/accounts` (identical for loans, cards). The Java code is the same as chapter 2. **What's new is how we package it.**

## 1. The problem
"It works on my machine." Your laptop has Java 21, your colleague has Java 17, and the server has a different OS and library versions.
Installing and configuring a JVM plus the right settings on every server by hand doesn't scale to dozens of services.

## 2. The idea
A **container** is a lightweight, isolated process that carries its own filesystem: your app, the exact JRE, and its libraries.

| Term | Analogy |
|------|---------|
| **Image** | A frozen recipe plus ingredients (read-only, built once) |
| **Container** | A dish cooked from that recipe (a running instance; you can start many) |
| **Registry** (Docker Hub) | The cookbook library you push and pull images from |
| **Layer** | Each build step is cached as a layer, so unchanged steps are reused |

Containers are **not** VMs: they share the host kernel, so they start in seconds and use far less memory.

## 3. Code walkthrough

### 3.1 Way one: a hand-written `Dockerfile`
`section4/accounts/Dockerfile` (comments trimmed):
```dockerfile
1  FROM eclipse-temurin:21-jdk
2  LABEL "org.opencontainers.image.authors"="eazybytes.com"
3  COPY target/accounts-0.0.1-SNAPSHOT.jar accounts-0.0.1-SNAPSHOT.jar
4  ENTRYPOINT ["java", "-jar", "accounts-0.0.1-SNAPSHOT.jar"]
```
- **Line 1, `FROM`**: start from an existing image that already contains Java 21 (Eclipse Temurin is a free OpenJDK build). You never
  start from nothing.
- **Line 2, `LABEL`**: metadata. (The commented-out `MAINTAINER` was the older, now deprecated way.)
- **Line 3, `COPY`**: put the fat jar into the image. The jar must exist first: build it with
  `mvn clean install -Dmaven.test.skip=true` (creates `target/…jar`).
- **Line 4, `ENTRYPOINT`**: the command run when the container starts. The **JSON-array form** (no shell) matters: it makes Java the
  main process (PID 1), so `docker stop`'s termination signal reaches it and Spring shuts down gracefully.

Build and run:
```bash
docker build . -t eazybytes/accounts:s4     # -t = name:tag
docker run -p 8080:8080 eazybytes/accounts:s4
```
`-p 8080:8080` means *host port : container port*. Without it, the app runs but you can't reach it from your machine.

**Weakness:** the whole jar is one layer. Change one line of code and Docker re-copies and re-uploads the entire ~50 MB jar, and you also carry the full JDK
(`-jdk`) when only a JRE is needed.

### 3.2 Way two: Buildpacks (no Dockerfile)
```bash
mvn spring-boot:build-image
```
Spring Boot inspects the project and uses Cloud Native **Buildpacks** to produce an image automatically, splitting it into sensible layers. Zero
Dockerfile, but it's slower and the images are larger.

### 3.3 Way three: Jib (what the project uses from here on)
In `pom.xml`:
```xml
1  <plugin>
2      <groupId>com.google.cloud.tools</groupId>
3      <artifactId>jib-maven-plugin</artifactId>
4      <version>3.5.1</version>
5      <configuration>
6          <to>
7              <image>eazybytes/${project.artifactId}:s14</image>
8          </to>
9      </configuration>
10 </plugin>
```
- **Lines 2–4**: Google's **Jib** builds the image straight from Maven, **without a Dockerfile** (`jib:build` can push to a registry with no local Docker daemon at all; `jib:dockerBuild` loads the image into your local Docker).
- **Line 7**: the image name. `${project.artifactId}` is replaced by `accounts`, `loans`, … so the same snippet works in every service. The tag (`s4`,
  `s14`, …) is bumped per section.
- Jib splits the image into **dependencies / resources / classes** layers. Change one class and only the tiny classes layer is rebuilt and pushed. It also
  places dependency jars under **`/app/libs`**. Remember that path; chapter 11 uses it to load the OpenTelemetry agent.

```bash
mvn compile jib:dockerBuild      # builds into your local Docker
```

### 3.4 Running several containers by hand: `docker-compose.yml`
`section4/accounts/docker-compose.yml` (one service shown; loans and cards repeat it):
```yaml
1  services:
2    accounts:
3      image: "eazybytes/accounts:s4"
4      container_name: accounts-ms
5      ports:
6        - "8080:8080"
7      deploy:
8        resources:
9          limits:
10           memory: 700m
11     networks:
12       - eazybank
...
30 networks:
31   eazybank:
32     driver: "bridge"
```
- **Line 2**: a compose *service* is a container definition. **Line 3**: which image. **Line 4**: a fixed name (otherwise compose invents one like `project-accounts-1`).
- **Lines 5–6**: publish the port to the host.
- **Lines 7–10**: **cap memory at 700 MB**. Without limits, one leaky JVM can starve every other container.
- **Lines 11–12 and 30–32**: put all services on one user-defined **bridge network** called `eazybank`. On such a network, containers reach each other **by service name**
  (`http://loans:8090`): Docker runs a tiny DNS for you. This is the foundation for everything that follows.

```bash
docker compose up -d      # start everything in the background
docker compose down       # stop and remove
```

## 4. Try it and break it
1. `docker ps` after `compose up`: three containers. `docker logs -f accounts-ms` to watch it boot.
2. `docker exec -it accounts-ms bash`: you're *inside* the container; run `ls`, `ps`. You'll see only the Java process.
3. Remove the `ports:` mapping and restart: the app is healthy but `localhost:8080` refuses. Ports must be published.
4. Set `memory: 100m` and watch the JVM get killed (OOMKilled in `docker inspect`).

## 5. Traps and senior notes
- **Never bake secrets or environment-specific config into the image.** One image must run in dev, QA and prod. That's chapter 6.
- **Tag images explicitly.** `latest` moves under you. This repo uses `s4`, `s14`… to pin versions.
- **Don't run the JDK where a JRE would do**, and prefer smaller base images in production (distroless/alpine variants).
- **A container should run one process.** That's why the database, broker, and each service are separate containers.
