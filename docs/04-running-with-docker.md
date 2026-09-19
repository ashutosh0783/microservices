# 04 – Running the full stack in Docker Desktop

This runs **section 14** (all services + Kafka + Keycloak + the observability stack) from the prebuilt images
`eazybytes/<service>:s14` on Docker Hub, so **no local build (Java/Maven) is needed**.

## Prerequisites
* Docker Desktop running, with about **6 GB or more RAM** assigned (the stack uses roughly 4.5 GB in total; the Java services are capped at 700 MB each).
* Free host ports: `3000 3100 3101 3102 4318 7080 8070 8071 8072 9090 9092 12345 3110`.
* Internet access. Images are pulled on first start, and the Config Server clones
  `https://github.com/eazybytes/eazybytes-config` at startup.

## Start / stop

```bash
cd section_14/docker-compose/default
docker compose -p eazybank up -d      # first run pulls ~20 images, allow several minutes
docker compose -p eazybank ps         # watch until everything is Up / healthy
docker compose -p eazybank down       # stop and remove (data is in-memory, so nothing is lost that matters)
```

`-p eazybank` names the Compose project, so Docker Desktop shows all containers grouped under **eazybank** in the
*Containers* tab. Use the same `-p` for every later compose command.

**Startup order** (enforced with `depends_on: condition: service_healthy`, about 2–3 min in total):
`kafka, configserver` → `eurekaserver` → `accounts, loans, cards` → `gatewayserver`. `message` needs only Kafka.
Until Config Server is healthy the others wait; if you open a URL too early, just retry.

## What you will see in Docker Desktop

| Group | Containers |
|-------|-----------|
| Business services | `accounts-ms`, `loans-ms`, `cards-ms`, `message-ms` |
| Platform | `configserver-ms`, `eurekaserver-ms`, `gatewayserver-ms`, `keycloak`, `kafka` |
| Observability | `prometheus`, `tempo`, `eazybank-grafana-1`, `eazybank-alloy-1`, `eazybank-read-1`, `eazybank-write-1`, `eazybank-backend-1`, `eazybank-gateway-1` (nginx in front of Loki), `eazybank-minio-1` |

Click a container, then **Logs** to watch a service, or **Inspect** and **Stats** for CPU and memory.
Ports and URLs are in [03-services-reference.md](03-services-reference.md#ports-at-a-glance).

## UIs to open

| URL | What to look at |
|-----|-----------------|
| http://localhost:8070 | **Eureka**: ACCOUNTS, LOANS, CARDS, GATEWAYSERVER registered |
| http://localhost:8071/accounts/default | **Config Server**: the JSON config it serves for `accounts` |
| http://localhost:8072/actuator/gateway/routes | **Gateway**: the three configured routes |
| http://localhost:7080 (`admin`/`admin`) | **Keycloak** admin console |
| http://localhost:3000 | **Grafana** → *Explore* → pick Loki (logs) / Prometheus (metrics) / Tempo (traces) |
| http://localhost:9090/targets | **Prometheus**: all six scrape targets should be `UP` |
| http://localhost:12345 | **Alloy** pipeline UI |

## Try the API

### 1. Public (GET) calls need no token
```bash
curl http://localhost:8072/eazybank/accounts/api/contact-info
curl http://localhost:8072/eazybank/loans/api/build-info
```

### 2. Mutating calls need a JWT, so create the Keycloak client once
The gateway expects roles `ACCOUNTS`, `CARDS`, `LOANS` in the token. Keycloak starts empty, so run the helper:
```bash
bash docs/scripts/setup-keycloak.sh
```
It creates the three roles and a client `eazybank-callcenter-cc` (secret `eazybank-secret`, client-credentials flow) that
holds all of them. Safe to re-run.

### 3. Get a token and call the API
```bash
TOKEN=$(curl -s -d grant_type=client_credentials -d client_id=eazybank-callcenter-cc \
  -d client_secret=eazybank-secret \
  http://localhost:7080/realms/master/protocol/openid-connect/token | python -c "import json,sys;print(json.load(sys.stdin)['access_token'])")

H=http://localhost:8072/eazybank
curl -X POST $H/accounts/api/create -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Madan Reddy","email":"tutor@eazybytes.com","mobileNumber":"4354437687"}'
curl -X POST "$H/loans/api/create?mobileNumber=4354437687" -H "Authorization: Bearer $TOKEN"
curl -X POST "$H/cards/api/create?mobileNumber=4354437687" -H "Authorization: Bearer $TOKEN"

# the aggregate call: accounts + loans + cards in one response
curl "$H/accounts/api/fetchCustomerDetails?mobileNumber=4354437687"
```
Without the `Authorization` header the POSTs return **401**. That proves the gateway is enforcing security.

### 4. Watch the event-driven part
```bash
docker logs message-ms  | grep "Sending"      # "Sending email…" and "Sending sms…"
docker logs accounts-ms | grep Communication  # "Updating Communication status for the account number …"
```

### 5. Watch resilience
```bash
docker stop loans-ms
curl "$H/accounts/api/fetchCustomerDetails?mobileNumber=4354437687"   # still 200, but loansDto is null
docker start loans-ms
```

### 6. Follow one request across every pillar
Make any call, then in Grafana *Explore*:
* **Tempo** → *Search* → service `accounts` → open a trace to see gateway → accounts → loans/cards spans.
* **Loki** → `{service_name="accounts-ms"}`. The `trace_id` in each log line links to the trace.
* **Prometheus** → e.g. `http_server_requests_seconds_count`.

(The Postman collection in the repo root has all of these requests pre-built. Point its variables at port `8072` /
`7080`.)

## Useful commands

| Task | Command |
|------|---------|
| Status of the stack | `docker compose -p eazybank ps` |
| Follow a service log | `docker logs -f accounts-ms` |
| Restart one service | `docker restart accounts-ms` (in-memory data for that service is lost) |
| Memory use | `docker stats --no-stream` |
| Remove everything incl. images | `docker compose -p eazybank down --rmi all -v` |

## Known caveats

* **Redis is missing.** The `cards` gateway route uses a Redis rate limiter, but the section 14 compose file has no
  Redis (only section 10 does). Requests still succeed because the limiter fails open, but no rate limiting occurs. To try
  it, add `redis: { image: redis, ports: ["6379:6379"], extends: {file: common-config.yml, service: network-deploy-service} }`
  and set `spring.data.redis.host: redis` for the gateway.
* **`eazybank-read-1` / `eazybank-write-1` show "unhealthy".** This is cosmetic. Their compose healthcheck calls
  `/bin/sh`, which does not exist in the `grafana/loki:3.6.2` image, while Loki itself answers `/ready`. Logs still flow.
* **Loki → MinIO endpoint (fixed in this repo).** Loki 3.6 rejects `endpoint: minio:9000`. It needs
  `http://minio:9000` (`observability/loki/loki-config.yaml`), otherwise chunk flushes fail with *"Custom endpoint was not a valid URI"*.
* **Data is in-memory.** H2 databases reset whenever a service container restarts.
* **Config comes from the course author's GitHub repo**, so behaviour or values can change if that repo changes, and
  startup needs internet access. To use your own copy, fork `eazybytes-config` and change `spring.cloud.config.server.git.uri` in
  `section_14/configserver/src/main/resources/application.yml`, then rebuild the image with Jib (`mvn compile jib:dockerBuild`).
* **Docker Desktop sleeping/pausing** the VM (laptop sleep) can leave Loki/Kafka clients reconnecting for a minute. They recover on their own.
* Keycloak is in `start-dev` mode with `admin/admin`: local development only.

## Running the other stages
| Want to see | Do |
|-------------|----|
| Sections 7–13 | `cd sectionN/docker-compose/default && docker compose -p eazybank-sN up -d` (images `eazybytes/*:sN` exist per section; section 13 needs RabbitMQ instead of Kafka) |
| A single service without Docker | `cd section_14/accounts && mvn spring-boot:run` (needs Config Server + Eureka + Kafka running, or set `spring.config.import` to `optional:` as it is by default) |
| Kubernetes | Enable Kubernetes in Docker Desktop, then `kubectl apply -f section_15/kubernetes/` |
| Helm | `helm install eazybank section_16/helm-new/environments/dev-env` |

Run only one stage at a time. The stages reuse the same ports and container names.
