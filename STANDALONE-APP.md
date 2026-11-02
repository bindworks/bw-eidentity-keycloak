# Standalone app behind Keycloak (own oauth2-proxy)

For an application that runs on **its own servers**: its own VM, its own Docker Compose stack, its own Traefik,
its own domain, often several sites (a web, an app, an admin, an API). It gets a gate of its own, an
oauth2-proxy that shares no cookie and no configuration with anything else, and **who may open it is decided
in Keycloak, by a role** (realm `bindworks`, https://id.bindworks.eu/realms/bindworks).

Services on our self-hosted Coolify (`*.demo.bindworks.eu`) do not need this guide: they get auth from its
shared gate, see [DEMO-PROTOTYPE.md](DEMO-PROTOTYPE.md).

- Every application gets its own Keycloak client, and that client gets a client role **`access`**. It is the
  gate: without it nobody gets in, whatever else they have. (Same idea as `linux-servers` `access` in bw-access.)
  An application with several environments gets **one client per environment** (`orbiso-dev`, `orbiso-prod`),
  so access to dev never opens prod.
- The role is enforced by **oauth2-proxy**, a small container next to the application's Traefik. It never
  carries the traffic: Traefik asks it about every request on a gated router (*ForwardAuth*) and then routes
  the request to the site itself. Gating a site is one label on its router; a path that must stay open is a
  router without that label.
- Nothing gated can be reached except through Traefik: no published ports, only 80 and 443 open to the
  internet.
- Taking the role away, or disabling the user, locks them out of an open session **within about a minute**
  (`--cookie-refresh=1m`). Measured for Orbiso with exactly the setup below (step 5), and before that in the
  OpenObserve stack (`bw-infra-openobserve` DESIGN.md pitfall 8).

```
browser ──https──> Traefik ── router with middleware keycloak-auth ──> www / app / builder / Studio …
                     │  forwardAuth: GET http://oauth2-proxy:4180/  + X-Forwarded-Host, -Uri, -Proto
                     ▼
                  oauth2-proxy ──── sessions ────> Valkey (memory only)
     no session ............ 302 → sign in at id.bindworks.eu, callback https://<the same host>/oauth2/callback
     session with role ..... 202 → Traefik passes the request on to the site
     session without role .. 403
```

These applications are **for Bindworks staff only**, and that part needs no work: the realm already refuses
everyone without the realm role `bindworks-user` (which every Google login gets through `/Companies/Bindworks`)
on any client that lacks the `non-bindworks-users-allowed-application-*` scope. A new client is staff-only by
default; **never add that scope here**. The role `access` then picks who among the staff gets in. Details in
[REALM-BINDWORKS.md](REALM-BINDWORKS.md).

The steps below use Orbiso's dev environment as the example; replace it everywhere:

| | Example (Orbiso dev) | Notes |
|---|---|---|
| Client ID | `orbiso-dev` | short, lowercase, one per environment; it is how the role shows up in Keycloak (`orbiso-dev` `access`) |
| Domain (`BASE_URL`) | `dev.orbiso.cz` | the sites are subdomains of it, all `https` |
| Gated hosts | `www`, `wb`, `orbook`, `app`, `builder`, `sb` | on Orbiso prod only `sb` (Studio) |
| Traefik cert resolver | `orbisoresolver` | whatever the server's Traefik calls its Let's Encrypt resolver |

The working configuration is in bw-orbiso: `deploy/docker-compose.yml` (the gate, and Studio) and
`deploy/docker-compose.dev.yml` (the other dev sites).

## 1. Keycloak: the client

*Clients → Create client*

1. General settings: Client type `OpenID Connect`, Client ID `orbiso-dev`, Name `Orbiso dev`,
   Description `Orbiso dev sites https://*.dev.orbiso.cz, Traefik ForwardAuth via oauth2-proxy. Gate: role access.`
   → Next
2. Capability config: Client authentication **On**, Authorization Off, authentication flow: **only Standard
   flow** ticked (untick Direct access grants), PKCE Method **`S256`** → Next
3. Login settings:

   | Field | Value |
   |---|---|
   | Root URL, Home URL | leave empty (several hosts), or the main site, e.g. `https://www.dev.orbiso.cz` |
   | Valid redirect URIs | **one line per gated host**: `https://www.dev.orbiso.cz/oauth2/callback`, `https://wb.dev.orbiso.cz/oauth2/callback`, `https://orbook.dev.orbiso.cz/oauth2/callback`, `https://app.dev.orbiso.cz/oauth2/callback`, `https://builder.dev.orbiso.cz/oauth2/callback`, `https://sb.dev.orbiso.cz/oauth2/callback` |
   | Valid post logout redirect URIs, Web origins | leave empty |

   Keycloak accepts `*` only at the end of a URI, never in the host, so every host is its own line. A host
   added to the gate later needs its line here too. (Orbiso prod has one: `https://sb.orbiso.cz/oauth2/callback`.)

   Save.

Then on the same client:

- PKCE Method, if the client was created without it: *Settings → Capability config* → `S256` → Save. (It
  makes Keycloak insist on PKCE; oauth2-proxy uses it either way because of `--code-challenge-method=S256`.)
- *Credentials*: copy the **Client secret** into the password manager. It goes to the server in step 3.
- Leave *Advanced → Authentication flow overrides* empty. The realm's browser flow is what keeps
  the Google login and the staff-only check in place.

## 2. Keycloak: the role and the audience

**Role** — *Clients → orbiso-dev → Roles → Create role*: Role name `access`, Description
`May open the Orbiso dev sites` → Save.

**Audience mapper** — *Clients → orbiso-dev → Client scopes → `orbiso-dev-dedicated` → Configure a new mapper →
Audience*:

| Field | Value |
|---|---|
| Name | `audience` |
| Included Client Audience | `orbiso-dev` |
| Add to ID token / Add to access token | **On** / **On** |

Save. oauth2-proxy's Keycloak guide requires it: it adds the client ID to the access token's `aud`, which
Keycloak otherwise leaves out. (oauth2-proxy v7.15.4 itself only checks the ID token's audience, which
Keycloak always sets, so a missing mapper does not show today.)

Check the result: *Clients → orbiso-dev → Client scopes → Evaluate*, pick a user who has the role (step 4),
then *Generated access token*. It must contain `"aud": [..., "orbiso-dev"]` and
`"resource_access": {"orbiso-dev": {"roles": ["access"]}}`. The roles come from the client scope `roles`,
which every new client has by default.

## 3. The server: oauth2-proxy and Valkey next to Traefik

The server already runs Traefik v3 (Orbiso: `traefik:v3.6`) with the Docker provider
(`exposedbydefault=false`), an `https` entrypoint `websecure`, HTTP redirected to HTTPS and a Let's Encrypt
resolver; every site is a Compose service with its own router labels. Add these two services to the stack:

```yaml
services:
  oauth2-proxy:
    # Same version as bw-orbiso and bw-infra-openobserve, where the 1-minute revocation was measured.
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.15.4
    restart: unless-stopped
    depends_on:
      - oauth2-proxy-valkey
    environment:
      OAUTH2_PROXY_CLIENT_SECRET: ${KEYCLOAK_CLIENT_SECRET}
      OAUTH2_PROXY_COOKIE_SECRET: ${OAUTH2_PROXY_COOKIE_SECRET}
    # Everything else as flags, not env vars: a mistyped flag stops the container,
    # while a mistyped env var (list options use plural names, OAUTH2_PROXY_ALLOWED_ROLES)
    # is silently ignored, and an ignored --allowed-role lets in every Keycloak user.
    command:
      - --provider=keycloak-oidc
      - --oidc-issuer-url=https://id.bindworks.eu/realms/bindworks
      - --client-id=orbiso-dev
      - --code-challenge-method=S256
      # THE GATE: <client id>:<client role>
      - --allowed-role=orbiso-dev:access
      - --email-domain=*
      # 202 = "let it through". oauth2-proxy never sees the sites themselves.
      - --upstream=static://202
      - --http-address=0.0.0.0:4180
      - --reverse-proxy=true
      - --skip-provider-button=true
      # No --redirect-url: oauth2-proxy builds it per host from X-Forwarded-Host as
      # https://<host>/oauth2/callback, so one gate serves every host.
      # The page to return to after sign-in is an absolute URL here (built from X-Forwarded-*);
      # without this, oauth2-proxy rejects it and always sends the user to "/".
      - --whitelist-domain=.${BASE_URL}
      # A cookie per host, never --cookie-domain: a domain-wide cookie would also reach the open
      # services. __Host- makes the browser refuse one planted by a sibling subdomain.
      - --cookie-name=__Host-oauth2_proxy
      - --cookie-secure=true
      # Re-check Keycloak every minute. Without it a session is never re-checked for 7 days,
      # so removing the role does nothing. Do NOT add --session-cookie-minimal: it drops the
      # refresh token and silently turns this off.
      - --cookie-refresh=1m
      - --cookie-expire=8h
      # Tokens stay in Valkey and the cookie only names the session (see below).
      - --session-store-type=redis
      - --redis-connection-url=redis://oauth2-proxy-valkey:6379
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.oauth2-proxy.loadbalancer.server.port=4180"
      # The middleware every gated router uses.
      - "traefik.http.middlewares.keycloak-auth.forwardauth.address=http://oauth2-proxy:4180/"
      - "traefik.http.middlewares.keycloak-auth.forwardauth.addAuthCookiesToResponse=__Host-oauth2_proxy"
      # Sign-in callback and sign-out on every gated host, above the sites' own routers.
      - "traefik.http.routers.oauth2.rule=(Host(`www.${BASE_URL}`) || Host(`wb.${BASE_URL}`) || Host(`orbook.${BASE_URL}`) || Host(`app.${BASE_URL}`) || Host(`builder.${BASE_URL}`) || Host(`sb.${BASE_URL}`)) && PathPrefix(`/oauth2/`)"
      - "traefik.http.routers.oauth2.entrypoints=websecure"
      - "traefik.http.routers.oauth2.tls.certresolver=orbisoresolver"
      - "traefik.http.routers.oauth2.service=oauth2-proxy"
      - "traefik.http.routers.oauth2.priority=500"

  # Memory only: no volume, no snapshots. A restart signs everyone out; Keycloak signs them
  # back in without a password while its own session lasts.
  oauth2-proxy-valkey:
    image: valkey/valkey:8.1-alpine
    restart: unless-stopped
    command: ["valkey-server", "--save", "", "--appendonly", "no"]
```

Neither service gets a `ports:` entry. Orbiso keeps one compose file for dev and prod and writes
`--client-id=orbiso-${DEPLOYED_ENVIRONMENT}` (and the same in `--allowed-role`), so each VM picks its own
client; the dev overlay widens the `/oauth2/` router to all six hosts, prod keeps only `sb`.

### Why these settings

- **`forwardauth.address` is `/`, not `/oauth2/auth`.** On `/` oauth2-proxy sends a browser without a session
  to Keycloak itself (302). `/oauth2/auth` only answers 401, and Traefik would need another middleware to turn
  that into a redirect.
- **A router for `/oauth2/` on every gated host**, priority above the sites (`500`), so the callback reaches
  oauth2-proxy and not the site. Every host on it also needs its line in *Valid redirect URIs* (step 1).
- **`--whitelist-domain=.<domain>` is required.** Without it the sign-in works but always lands on `/` instead
  of the page asked for (log: *Rejecting invalid redirect … domain / port not in whitelist*). Orbiso's
  end-to-end test found this.
- **`addAuthCookiesToResponse`.** On a 2xx answer Traefik drops the auth server's `Set-Cookie` unless the
  cookie is named here. A refresh re-sends the cookie with a new expiry, which would otherwise never reach the
  browser.
- **Sessions in Valkey (`--session-store-type=redis`).** The tokens stay on the server and the cookie only
  names the session, so a refresh changes nothing the browser has to receive, and the cookie stays small. The
  Redis store also locks a session while it is being refreshed, so the many parallel requests of one page load
  do not all refresh at once; the cookie store has no such lock.
- **`__Host-` cookie per host.** Signing in on the second host goes through the Keycloak session without a
  password, so one cookie per host costs nothing, and the cookie never reaches the open services.
- **Fails closed.** The middleware is defined in oauth2-proxy's own labels. If that container is not
  running (missing secret, crash loop), Traefik loses the middleware and the gated routers stop answering
  with the site. The open routers keep working.

### Gating a site

One label on the site's router:

```yaml
  builder:
    labels:
      - "traefik.http.routers.builder.middlewares=keycloak-auth"
```

A router that already has a middleware lists both, comma-separated (`keycloak-auth,other`).

### Secrets and deploy

Put both secrets in the server's env file next to the compose files (Orbiso: `sb/.env` on each VM), never into
the compose file:

```bash
KEYCLOAK_CLIENT_SECRET=<from step 1>
OAUTH2_PROXY_COOKIE_SECRET=<new random value for every application and environment>
```

```bash
openssl rand -base64 32 | tr -- '+/' '-_'
```

Deploy with the stack's usual command (Orbiso: `./orbiso compose up -d`). Traefik picks up the new labels
without a restart.

## 4. Giving people access

Best through a group, as with the other applications (*Groups → (group) → Role mapping → Assign role →
Filter by clients* → tick `orbiso-dev` `access` → Assign):

| Who should get in | Where to assign `orbiso-dev` `access` |
|---|---|
| everyone at Bindworks | the group `/Companies/Bindworks` |
| a team | its existing group, or a new one under the parent group `Apps`, e.g. `/Apps/orbiso-dev` (kept together the way the `*-devs` groups sit under `Project Developers`) |
| one person | *Users → (user) → Role mapping → Assign role* |

Production gets its own, smaller list: grant `orbiso-prod` `access` only to people who need production (for
Orbiso prod: Studio on the production database).

Then add the application to the table in [REALM-BINDWORKS.md](REALM-BINDWORKS.md), section *Application-specific
roles (groups)*, so the realm description stays complete.

**Revoking**: remove the person from the group (or the role from the group / user), or disable the user.
An open session ends within about a minute; nobody needs to sign out. Keycloak's session limits (idle 30 min,
max 10 h) end sessions independently of this.

## 5. Check before telling people

1. Nobody signed in, every gated host:
   ```bash
   for h in www wb orbook app builder sb; do
     curl -s -o /dev/null -w "$h %{http_code} %{redirect_url}\n" "https://$h.dev.orbiso.cz/"
   done
   ```
   Expect `302 https://id.bindworks.eu/realms/bindworks/protocol/openid-connect/auth?...` for each, with a
   `redirect_uri` that names that same host. A `200` means the site's router lacks `keycloak-auth`.
2. The open paths stay open (see [Paths that must stay open](#paths-that-must-stay-open)), e.g.
   `https://sb.dev.orbiso.cz/rest/v1/` answers `401` from the API (not a `302`),
   `https://app.dev.orbiso.cz/.well-known/assetlinks.json` answers `200`.
3. A user **with** `access` (directly or through a group) opens a deep link (a page other than `/`), signs in
   and lands on that page. A second gated host must not ask for the password again.
4. A user **without** it signs in at Keycloak and gets oauth2-proxy's 403 page.
5. Remove the role from user 3 while they have a site open: within about a minute the next request gets 403.
   Give it back.

What Orbiso's end-to-end test (Keycloak 26, Traefik 3.6, oauth2-proxy v7.15.4, Valkey 8.1, the flags and
labels above) measured:

| Step | Result |
|---|---|
| user with the role opens `/programs/42?tab=x` | 302 to Keycloak, back exactly on `/programs/42?tab=x`, 200 |
| second host | through the Keycloak session, no password, 200 |
| 65 s later | log `Refreshing session … SessionAge: 1m4s`, still 200 |
| role removed | 200 right away (inside the minute), 403 after 65 s, then 302 to sign in |
| user without the role | 403 after signing in |
| role given back, sign in | 200 |

## If the application has its own Keycloak login

Keep the gate in front of it anyway. Whether an application can refuse a user who lacks a role differs from
one to the next, and one forgotten setting opens it to the whole company.
With the gate, the application's own login only decides *who* the user is and what they may do inside.

- Let the application use the same client: add its own callback URL (from its docs) to *Valid redirect URIs*
  and give it the issuer `https://id.bindworks.eu/realms/bindworks`, the client ID and the secret. On the
  first visit the browser passes through Keycloak twice; the user is asked only once.
- Permissions inside the application: add more client roles next to `access` (e.g. `admin`) and assign them
  the same way. They are in the access token under `resource_access.orbiso-dev.roles`. For an application
  that reads a flat claim from the ID token or userinfo instead, add a mapper *User Client Role* (Client ID
  `orbiso-dev`, Token Claim Name `roles`, Multivalued On) to `orbiso-dev-dedicated`.
- The sites get no user headers from the gate by default. Passing them on (for an application that trusts a
  header, e.g. Grafana's `auth.proxy`) takes oauth2-proxy `--set-xauthrequest` and the middleware's
  `authResponseHeaders`; not tried on Orbiso. It is only safe because the site cannot be reached except
  through Traefik.

## Paths that must stay open

Webhooks, callers from outside with their own API tokens, mobile clients, files that Apple and Google fetch:
the gate blocks them too. Give exactly those paths a router of their own **without** `keycloak-auth`, as
narrow as possible. Whatever it matches is open to the whole internet, so the application must authenticate
it itself. Orbiso's open paths:

```yaml
  app:
    labels:
      # The site's own router (rule, priority 1, middlewares=keycloak-auth) as usual. Apple and Google
      # fetch these two files to verify deep links, so they get a router of their own without the gate.
      # It has no explicit priority, so Traefik ranks it by the length of its rule, above priority 1.
      - "traefik.http.routers.app-well-known.rule=Host(`app.${BASE_URL}`) && (Path(`/.well-known/apple-app-site-association`) || Path(`/.well-known/assetlinks.json`))"
      - "traefik.http.routers.app-well-known.entrypoints=websecure"
      - "traefik.http.routers.app-well-known.tls.certresolver=orbisoresolver"
      - "traefik.http.routers.app-well-known.service=app"

  kong:
    labels:
      # API and Studio share sb.*. The API: the apps send their own tokens, so no gate (priority 100).
      - "traefik.http.routers.sb-api.rule=Host(`sb.${BASE_URL}`) && (PathPrefix(`/auth/`) || PathPrefix(`/rest/`) || PathPrefix(`/realtime/`) || PathPrefix(`/storage/`) || PathPrefix(`/functions/`))"
      - "traefik.http.routers.sb-api.priority=100"
      # The browser sends Studio's sign-in cookie to the API too; the API needs none, so drop it.
      - "traefik.http.middlewares.strip-cookie.headers.customrequestheaders.Cookie="
      - "traefik.http.routers.sb-api.middlewares=strip-cookie"
      # Studio: everything else on sb.*, gated (priority 1).
      - "traefik.http.routers.sb-dashboard.rule=Host(`sb.${BASE_URL}`) && PathPrefix(`/`)"
      - "traefik.http.routers.sb-dashboard.priority=1"
      - "traefik.http.routers.sb-dashboard.middlewares=keycloak-auth"
```

(The existing routers' `entrypoints`, `tls` and `service` lines are left out.) Whole hosts that stay open
(Orbiso: `email.*` with the e-mail templates, `ps.*` with PowerSync) simply have no `keycloak-auth`.

**Signing out** at `https://<host>/oauth2/sign_out` only drops oauth2-proxy's cookie for that host; the next
request signs the user in again through the Keycloak session, without a prompt. That is ordinary single
sign-on. To end a session for real, sign out of Keycloak (account console, or the user's *Sessions* tab).

## Troubleshooting

oauth2-proxy logs the reason of every refusal: `docker compose logs oauth2-proxy` on the server (Orbiso:
`./orbiso compose logs oauth2-proxy`).

| Symptom | Cause |
|---|---|
| Keycloak: *Invalid parameter: redirect_uri* | the host is missing from *Valid redirect URIs*, or differs in scheme or path |
| Error 500 after Keycloak, log mentions the **audience** | `--client-id` differs from the Client ID in Keycloak |
| Error 500, log says the e-mail **isn't verified** | the user's *Email verified* is off in Keycloak; turn it on. Google users always have it |
| 403 for someone who has the role | the role is on another client (e.g. `orbiso-dev` instead of `orbiso-prod`), or `--allowed-role` / `--client-id` do not match the Client ID exactly; check with *Evaluate* (step 2) |
| Keycloak refuses someone with an access error before the app | they are not in `/Companies/Bindworks` (no `bindworks-user`), e.g. an account made by hand rather than through Google |
| A site opens without signing in | its router lacks `middlewares=keycloak-auth`, a wider open router catches the path, or a published port skips Traefik |
| After sign-in always on `/`, not the page asked for; log *Rejecting invalid redirect … not in whitelist* | `--whitelist-domain` missing or not covering the host |
| Every gated site stops answering after a deploy, open paths still work | oauth2-proxy is not running (often a missing `KEYCLOAK_CLIENT_SECRET` / `OAUTH2_PROXY_COOKIE_SECRET`), so Traefik has no `keycloak-auth` |
| Endless redirects | the site is served over `http://` without the redirect to `https`; with `--cookie-secure=true` the cookie is never sent back |
| Log warning *--reverse-proxy is enabled but no --trusted-proxy-ip* | expected: oauth2-proxy has no published port, only Traefik and the stack's own containers reach it |
