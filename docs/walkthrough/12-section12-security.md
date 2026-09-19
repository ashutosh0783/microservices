# Chapter 12: Microservices security with OAuth2 and Keycloak (`section_12/`, final form in `section_14/`)

New in this section: a **Keycloak** container, `SecurityConfig.java` and `KeycloakRoleConverter.java` in the gateway, and a `jwk-set-uri` setting.

## 1. The problem
Until now anyone who can reach the gateway can `POST /create` or `DELETE` a customer. We need to answer two different questions:

| Question | Name | Example |
|----------|------|---------|
| *Who are you?* | **Authentication** (AuthN) | "I'm the call-centre app" |
| *What may you do?* | **Authorization** (AuthZ) | "The call-centre app may create accounts but not cards" |

Doing this inside each service means 3× the code and 3× the bugs. Doing it **once, at the gateway**, is simpler, and it is the pattern used here.

## 2. The idea: OAuth2 tokens instead of passwords

**Never let every service handle passwords.** Instead, a central **authorization server** (Keycloak) authenticates the caller once and issues a short-lived **access token**. Callers present that token on each request.
Analogy: a **hotel key card**. You show ID once at reception (Keycloak), get a card (token) that opens only *your* room and expires at checkout. Doors (services) don't know you, they just check that
the card is genuine, unexpired and opens this door.

**The cast:**

| OAuth2 role | Who it is here |
|-------------|----------------|
| **Authorization server** | Keycloak (`:7080`): authenticates and issues tokens |
| **Resource server** | The **gateway**: protects the APIs, validates tokens |
| **Client** | The app calling the API (Postman, the call-centre app) |
| **Resource owner** | The user (only in the authorization-code flow) |

**The token** is a **JWT** (JSON Web Token): `header.payload.signature`, each part Base64-encoded. The payload holds *claims* (issuer, expiry, roles…). The signature is made with Keycloak's **private key**;
anyone with the matching **public key** can verify that the token wasn't forged or altered, **without calling Keycloak**. That's why JWT validation is fast and stateless.

**Two flows you need to know:**
1. **Client credentials**: machine to machine. The app sends `client_id` + `client_secret` and gets a token. No human. *(What we use in the demo.)*
2. **Authorization code**: a human logs in through a browser and the app gets a token on the user's behalf. Used by web/mobile apps.

## 3. Code walkthrough

### 3.1 Keycloak in Compose
`docker-compose/default/docker-compose.yml`:
```yaml
1  keycloak:
2    image: quay.io/keycloak/keycloak:26.4.7
3    container_name: keycloak
4    ports:
5      - "127.0.0.1:7080:8080"
6    environment:
7      KC_BOOTSTRAP_ADMIN_USERNAME: "admin"
8      KC_BOOTSTRAP_ADMIN_PASSWORD: "admin"
9    command: "start-dev"
10   extends:
11     file: common-config.yml
12     service: network-deploy-service
```
- **Line 5**: host port **7080** maps to Keycloak's 8080, and **`127.0.0.1:`** binds it to your machine *only* (other computers on your network can't reach it). A good habit for admin consoles.
- **Lines 7–8**: bootstrap admin login. **Line 9, `start-dev`**: development mode (H2 storage, HTTP allowed, relaxed hostname checks). **Never** `start-dev` in production.

Keycloak starts *empty*: there are no roles or clients yet. In the course you click these through the admin UI; in this repo I added `docs/scripts/setup-keycloak.sh` which does it through the Admin REST API. It creates:
- realm roles **ACCOUNTS**, **CARDS**, **LOANS**;
- a client **`eazybank-callcenter-cc`** with `serviceAccountsEnabled: true` (that's what enables the *client credentials* flow), a secret, and all three roles assigned to its **service account** (the client's own "user").

### 3.2 Getting a token
```bash
curl -s -d grant_type=client_credentials -d client_id=eazybank-callcenter-cc \
        -d client_secret=eazybank-secret \
        http://localhost:7080/realms/master/protocol/openid-connect/token
# → {"access_token":"eyJhbGciOi...","expires_in":60,"token_type":"Bearer", ...}
```
The URL shape is `/realms/<realm>/protocol/openid-connect/token`. We use the built-in `master` realm for simplicity (real projects create their own realm).

What's inside that token? I decoded the payload of a real one from this stack:
```json
{ "iss": "http://localhost:7080/realms/master",
  "azp": "eazybank-callcenter-cc",
  "exp": 1789811462,
  "realm_access": { "roles": ["LOANS","default-roles-master","ACCOUNTS","offline_access","uma_authorization","CARDS"] },
  "preferred_username": "service-account-eazybank-callcenter-cc" }
```
(To see your own: copy a token to jwt.io, or decode the middle part with Base64.) Note **`realm_access.roles`**: that's where Keycloak puts roles, and it is exactly what the next class reads.

### 3.3 Telling the gateway how to verify tokens: `application.yml`
```yaml
1  spring:
2    security:
3      oauth2:
4        resourceserver:
5          jwt:
6            jwk-set-uri: "http://localhost:7080/realms/master/protocol/openid-connect/certs"
```
- **Line 6, `jwk-set-uri`**: the URL of Keycloak's **public keys** (a JWK Set). At startup/first use the gateway downloads them and uses them to check every token's signature. This is the key mechanism.
- In Docker Compose the URL is overridden with an env var, because *inside* the network Keycloak isn't `localhost`:
  `SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK-SET-URI: "http://keycloak:8080/realms/master/protocol/openid-connect/certs"`.
- **Senior note:** the token's `iss` claim says `http://localhost:7080/...`, while the gateway fetches keys from `http://keycloak:8080/...`. That works only because we configured `jwk-set-uri` (which checks the **signature**), not
  `issuer-uri` (which also insists on matching the `iss` claim). It's a common Docker-networking gotcha: if you switch to `issuer-uri` and the two host names differ, every token is rejected.
- The dependency is `spring-boot-starter-oauth2-resource-server`.

### 3.4 The security rules: `SecurityConfig.java`
```java
1  @Configuration
2  @EnableWebFluxSecurity
3  public class SecurityConfig {
4      @Bean
5      public SecurityWebFilterChain springSecurityFilterChain(ServerHttpSecurity serverHttpSecurity) {
6          serverHttpSecurity.authorizeExchange(exchanges -> exchanges.pathMatchers(HttpMethod.GET).permitAll()
7                  .pathMatchers("/eazybank/accounts/**").hasRole("ACCOUNTS")
8                  .pathMatchers("/eazybank/cards/**").hasRole("CARDS")
9                  .pathMatchers("/eazybank/loans/**").hasRole("LOANS"))
10                 .oauth2ResourceServer(oAuth2ResourceServerSpec -> oAuth2ResourceServerSpec
11                         .jwt(jwtSpec -> jwtSpec.jwtAuthenticationConverter(grantedAuthoritiesExtractor())));
12         serverHttpSecurity.csrf(csrfSpec -> csrfSpec.disable());
13         return serverHttpSecurity.build();
14     }
15     private Converter<Jwt, Mono<AbstractAuthenticationToken>> grantedAuthoritiesExtractor() {
16         JwtAuthenticationConverter jwtAuthenticationConverter = new JwtAuthenticationConverter();
17         jwtAuthenticationConverter.setJwtGrantedAuthoritiesConverter(new KeycloakRoleConverter());
18         return new ReactiveJwtAuthenticationConverterAdapter(jwtAuthenticationConverter);
19     }
20 }
```
- **Line 2, `@EnableWebFluxSecurity`**: the **reactive** flavour of Spring Security (the gateway is WebFlux; the servlet `@EnableWebSecurity` would not work here).
- **Line 5**: we define the **filter chain**, the ordered checks each request passes through.
- **Line 6, `pathMatchers(HttpMethod.GET).permitAll()`**: **every GET is public**, on every path. Reading is open; only writes are protected. (A deliberate simplification: real banks would not do this.)
- **Lines 7–9, the rules for everything else**: *the first rule that matches wins, so order matters.* A `POST` to `/eazybank/accounts/api/create` skips line 6 (not a GET), matches line 7 and requires the role `ACCOUNTS`.
  `hasRole("ACCOUNTS")` looks for an authority named **`ROLE_ACCOUNTS`** (Spring adds the `ROLE_` prefix), which is why the converter below adds it.
  **What about a request that matches no rule** (e.g. `POST /actuator/refresh` on the gateway)? I tested it: it is **denied with 401** when no token is sent. In the reactive stack an exchange that no rule matches is not waved through, so this list is effectively
  "deny by default". Many teams still end the list with an explicit `.anyExchange().authenticated()` (or `.denyAll()`) so the intent is visible to the next reader; this project does not.
- **Lines 10–11, `oauth2ResourceServer().jwt(...)`**: "treat this app as a resource server that accepts **Bearer JWTs**". It (a) extracts the token from the `Authorization: Bearer …` header, (b) verifies signature and expiry with the keys from 3.3, and
  (c) uses **our converter** to turn claims into authorities.
- **Line 12, `csrf.disable()`**: CSRF protection defends browser sessions/cookies. An API that authenticates by a header token (not cookies) isn't vulnerable in that way, so it's standard to disable it. **Don't disable it on cookie-based apps.**
- **Lines 15–19**: adapter plumbing: Spring's JWT converter is blocking-style, and `ReactiveJwtAuthenticationConverterAdapter` wraps it for WebFlux (returning a `Mono`).

### 3.5 Translating Keycloak roles: `KeycloakRoleConverter.java`
```java
2  public class KeycloakRoleConverter  implements Converter<Jwt, Collection<GrantedAuthority>> {
3      @Override
4      public Collection<GrantedAuthority> convert(Jwt source) {
5          Map<String, Object> realmAccess = (Map<String, Object>) source.getClaims().get("realm_access");
6          if (realmAccess == null || realmAccess.isEmpty()) {
7              return new ArrayList<>();
8          }
9          Collection<GrantedAuthority> returnValue = ((List<String>) realmAccess.get("roles"))
10                 .stream().map(roleName -> "ROLE_" + roleName)
11                 .map(SimpleGrantedAuthority::new)
12                 .collect(Collectors.toList());
13         return returnValue;
14     }
15 }
```
- **Why it exists:** Spring Security doesn't know Keycloak stores roles at `realm_access.roles`. By default it would only turn the `scope` claim into authorities. So we teach it.
- **Line 5**: get the `realm_access` claim (a JSON object → `Map`). **Lines 6–8**: no such claim → the user has **no authorities** (empty list): safe default, and all protected calls are denied.
- **Lines 9–12**: take the list of role names, prefix each with `ROLE_` (`ACCOUNTS` → `ROLE_ACCOUNTS`), and wrap in `SimpleGrantedAuthority`. Now `hasRole("ACCOUNTS")` from 3.4 matches.
- The unchecked casts `(Map<String,Object>)` and `(List<String>)` are a small risk: a malformed token could throw `ClassCastException`. Fine for a lab, worth hardening in production.

## 4. Try it and break it (verified on the running stack)
I ran the same `POST /eazybank/accounts/api/create` four ways:

| Request | Result | Why |
|---------|--------|-----|
| No `Authorization` header | **401 Unauthorized** | Not authenticated |
| `Authorization: Bearer garbage` | **401 Unauthorized** | Signature check fails |
| Valid token of the Keycloak **admin** user (has no `ACCOUNTS` role) | **403 Forbidden** | Authenticated, but not authorized |
| Valid token from `eazybank-callcenter-cc` (has `ACCOUNTS`) | **201 Created** | ✔ |

**Remember: 401 = "I don't know who you are". 403 = "I know who you are, and you may not do this."** Juniors mix these up constantly.

More to try:
- Wait for the token to expire (60 s by default in this Keycloak) and retry → 401.
- Remove the `CARDS` role from the client in Keycloak, get a new token, `POST /eazybank/cards/api/create` → 403 while accounts still works. (Roles are read from the token, so **you need a fresh token** after changing roles.)
- `GET /eazybank/accounts/api/contact-info` with no token → 200 (line 6). But `POST /eazybank/other/x` or `POST /actuator/refresh` with no token → 401 (matches no rule, so denied).
- Authorization-code flow: create a client with *standard flow* enabled, open Keycloak's `/auth` URL in a browser, log in, and exchange the code for a token (Postman's *OAuth 2.0* tab does this; see the `gatewayserver_security` folder in the collection).

## 5. Traps and senior notes
- **JWTs can't be revoked easily.** A stolen token works until it expires, so keep lifetimes short (minutes) and use refresh tokens.
- **Validate `aud`/`iss` in production.** Signature-only checking (as here) trusts any token signed by that Keycloak, including one meant for a different API.
- **Downstream services here trust the gateway completely** (no token check inside accounts/loans/cards) and are unreachable from outside only because their ports aren't published. In stricter designs (zero trust) every service validates the JWT too, or you use mTLS/a service mesh (course section 19).
- **Never commit real client secrets.** `eazybank-secret` and `admin/admin` are demo values.
- **Don't roll your own auth.** The value of Keycloak/Auth0/Okta is that password storage, MFA, brute-force protection and token signing are done by specialists.
