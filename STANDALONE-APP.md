# Standalone app behind Keycloak (own oauth2-proxy)

For an application that runs on its own in Coolify — a backend, its own data, perhaps its own login, its own
domain — where one more container next to it is no trouble. The application gets its own oauth2-proxy, so it
shares no cookie and no gate with anything else, and **who may open it is decided in Keycloak, by a role**
(realm `bindworks`, https://id.bindworks.eu/realms/bindworks).

Static prototypes on `*.demo.bindworks.eu` do not need any of this: they share one gate and are added by
clicking, see [DEMO-PROTOTYPE.md](DEMO-PROTOTYPE.md).

- Every application gets its own Keycloak client, and that client gets a client role **`access`**. It is the
  gate: without it nobody gets in, whatever else they have. (Same idea as `linux-servers` `access` in bw-access.)
- The role is enforced by **oauth2-proxy**, a small container that runs next to the application in the same
  Coolify resource. The domain points at oauth2-proxy; the application itself has no domain and no published
  port, so there is no way around it.
- Taking the role away, or disabling the user, locks them out of an open session **within about a minute**
  (`--cookie-refresh=1m`, measured in the OpenObserve stack, `bw-infra-openobserve` DESIGN.md pitfall 8).

```
browser ──https──> Coolify proxy ──> oauth2-proxy :4180 ──> app :3000   (internal only)
                                        │
                                        ├─ no session            → sign in at id.bindworks.eu
                                        └─ no role <client>:access → 403
```

These applications are **for Bindworks staff only**, and that part needs no work: the realm already refuses
everyone without the realm role `bindworks-user` (which every Google login gets through `/Companies/Bindworks`)
on any client that lacks the `non-bindworks-users-allowed-application-*` scope. A new client is staff-only by
default; **never add that scope here**. The role `access` then picks who among the staff gets in. Details in
[REALM-BINDWORKS.md](REALM-BINDWORKS.md).

The steps below use an example; replace it everywhere:

| | Example | Notes |
|---|---|---|
| Client ID | `wiki` | short, lowercase; it is how the role shows up in Keycloak (`wiki` `access`) |
| Domain | `wiki.bind.works` | the public address, `https` |
| Upstream | `http://app:3000` | the application's Compose service name and the port it listens on inside its container |

## 1. Keycloak: the client

*Clients → Create client*

1. General settings: Client type `OpenID Connect`, Client ID `wiki`, Name `Wiki`,
   Description `Coolify app https://wiki.bind.works, behind oauth2-proxy. Gate: role access.` → Next
2. Capability config: Client authentication **On**, Authorization Off, authentication flow: **only Standard
   flow** ticked (untick Direct access grants), PKCE Method **`S256`** → Next
3. Login settings:

   | Field | Value |
   |---|---|
   | Root URL, Home URL | `https://wiki.bind.works` |
   | Valid redirect URIs | `https://wiki.bind.works/oauth2/callback` |
   | Valid post logout redirect URIs, Web origins | leave empty |

   Save.

Then on the same client:

- PKCE Method, if the client was created without it: *Settings → Capability config* → `S256` → Save. (It
  makes Keycloak insist on PKCE; oauth2-proxy uses it either way because of `--code-challenge-method=S256`.)
- *Credentials*: copy the **Client secret** into the password manager. It goes to Coolify in step 3.
- Leave *Advanced → Authentication flow overrides* empty. The realm's browser flow is what keeps
  the Google login and the staff-only check in place.

## 2. Keycloak: the role and the audience

**Role** — *Clients → wiki → Roles → Create role*: Role name `access`, Description `May open the Wiki` → Save.

**Audience mapper** — *Clients → wiki → Client scopes → `wiki-dedicated` → Configure a new mapper → Audience*:

| Field | Value |
|---|---|
| Name | `audience` |
| Included Client Audience | `wiki` |
| Add to ID token / Add to access token | **On** / **On** |

Save. oauth2-proxy's Keycloak guide requires it: it adds the client ID to the access token's `aud`, which
Keycloak otherwise leaves out. (oauth2-proxy v7.15.4 itself only checks the ID token's audience, which
Keycloak always sets, so a missing mapper does not show today.)

Check the result: *Clients → wiki → Client scopes → Evaluate*, pick a user who has the role (step 4), then
*Generated access token*. It must contain `"aud": [..., "wiki"]` and `"resource_access": {"wiki": {"roles":
["access"]}}`. The roles come from the client scope `roles`, which every new client has by default.

## 3. Coolify: oauth2-proxy next to the application

The application must be a **Docker Compose** resource, so that both containers are in one resource and
share its private network. Add this service to its compose file:

```yaml
services:
  app:
    # the application, unchanged. In Coolify it must have NO domain, and it must
    # never get a `ports:` entry: either one is a way in that skips the gate.
    image: …

  oauth2-proxy:
    # Same version as bw-infra-openobserve, where the 1-minute revocation was measured.
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.15.4
    restart: unless-stopped
    environment:
      OAUTH2_PROXY_CLIENT_SECRET: ${KEYCLOAK_CLIENT_SECRET}
      OAUTH2_PROXY_COOKIE_SECRET: ${OAUTH2_PROXY_COOKIE_SECRET}
    # Everything else as flags, not env vars: a mistyped flag stops the container,
    # while a mistyped env var (list options use plural names, OAUTH2_PROXY_ALLOWED_ROLES)
    # is silently ignored, and an ignored --allowed-role lets in every Keycloak user.
    command:
      - --provider=keycloak-oidc
      - --oidc-issuer-url=https://id.bindworks.eu/realms/bindworks
      - --client-id=wiki
      - --code-challenge-method=S256
      - --redirect-url=https://wiki.bind.works/oauth2/callback
      # THE GATE: <client id>:<client role>
      - --allowed-role=wiki:access
      - --email-domain=*
      - --upstream=http://app:3000
      - --http-address=0.0.0.0:4180
      - --reverse-proxy=true
      - --skip-provider-button=true
      - --cookie-secure=true
      # Re-check Keycloak every minute. Without it a session is never re-checked for 7 days,
      # so removing the role does nothing. Do NOT add --session-cookie-minimal: it drops the
      # refresh token and silently turns this off.
      - --cookie-refresh=1m
      - --cookie-expire=4h
```

In the Coolify resource:

1. **Environment Variables**: set `KEYCLOAK_CLIENT_SECRET` (from step 1) and `OAUTH2_PROXY_COOKIE_SECRET`,
   a new random value for every application:
   ```bash
   openssl rand -base64 32 | tr -- '+/' '-_'
   ```
2. **Domains**: on the `oauth2-proxy` service set `https://wiki.bind.works:4180` (the port tells Coolify where
   oauth2-proxy listens). On the `app` service **remove** the domain.
3. Deploy.

**The application is a plain Application (Dockerfile, Nixpacks, image), not Docker Compose.** It cannot get a
second container, so recreate it as a Docker Compose resource: an `app` service with the same `image:`, or,
for a Git repository, the *Docker Compose* build pack with a compose file in the repository whose `app`
service has `build: .`. Move the domain over and delete the old Application once the new one works.
Services from Coolify's catalogue are Docker Compose already: edit their compose file and add the service.

## 4. Giving people access

Best through a group, as with the other applications (*Groups → (group) → Role mapping → Assign role →
Filter by clients* → tick `wiki` `access` → Assign):

| Who should get in | Where to assign `wiki` `access` |
|---|---|
| everyone at Bindworks | the group `/Companies/Bindworks` |
| a team | its existing group, or a new one under the parent group `Apps`, e.g. `/Apps/wiki` (kept together the way the `*-devs` groups sit under `Project Developers`) |
| one person | *Users → (user) → Role mapping → Assign role* |

Then add the application to the table in [REALM-BINDWORKS.md](REALM-BINDWORKS.md), section *Application-specific
roles (groups)*, so the realm description stays complete.

**Revoking**: remove the person from the group (or the role from the group / user), or disable the user.
An open session ends within about a minute; nobody needs to sign out. Keycloak's session limits (idle 30 min,
max 10 h) end sessions independently of this.

## 5. Check before telling people

1. Nobody signed in:
   ```bash
   curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://wiki.bind.works/
   ```
   Expect `302 https://id.bindworks.eu/realms/bindworks/protocol/openid-connect/auth?...`.
   A `200` means the application is reachable without the gate: its service still has a domain.
2. A user **with** `access` (directly or through a group) signs in and sees the application.
3. A user **without** it signs in at Keycloak and gets oauth2-proxy's 403 page.
4. Remove the role from user 2 while they have the application open: within about a minute the next
   request gets 403. Give it back.

## If the application has its own Keycloak login

Keep the gate in front of it anyway. Whether an application can refuse a user who lacks a role differs from
one to the next, and one forgotten setting opens it to the whole company.
With the gate, the application's own login only decides *who* the user is and what they may do inside.

- Let the application use the same client: add its own callback URL (from its docs) to *Valid redirect URIs*
  and give it the issuer `https://id.bindworks.eu/realms/bindworks`, the client ID and the secret. On the
  first visit the browser passes through Keycloak twice; the user is asked only once.
- Permissions inside the application: add more client roles next to `access` (e.g. `admin`) and assign them
  the same way. They are in the access token under `resource_access.wiki.roles`. For an application that
  reads a flat claim from the ID token or userinfo instead, add a mapper *User Client Role* (Client ID
  `wiki`, Token Claim Name `roles`, Multivalued On) to `wiki-dedicated`.
- An application that can trust a header (e.g. Grafana's `auth.proxy`) can skip its own login: oauth2-proxy
  passes `X-Forwarded-Email`, `X-Forwarded-User` and `X-Forwarded-Preferred-Username` to the upstream.
  That is only safe because the application cannot be reached except through oauth2-proxy.

## Paths that must stay open

Webhooks, callers from outside with their own API tokens, mobile clients: the gate blocks them too.
Exempt exactly those paths, as narrowly as possible, e.g. `--skip-auth-route=POST=^/api/webhooks/`.
Whatever matches is open to the whole internet, so the application must authenticate it itself.

**Signing out** at `https://wiki.bind.works/oauth2/sign_out` only drops oauth2-proxy's cookie; the next
request signs the user in again through the Keycloak session, without a prompt. That is ordinary single
sign-on. To end a session for real, sign out of Keycloak (account console, or the user's *Sessions* tab).

## Troubleshooting

oauth2-proxy logs the reason of every refusal: Coolify → the resource → *Logs* → `oauth2-proxy`.

| Symptom | Cause |
|---|---|
| Keycloak: *Invalid parameter: redirect_uri* | *Valid redirect URIs* differ from `--redirect-url` (scheme, host, trailing path) |
| Error 500 after Keycloak, log mentions the **audience** | `--client-id` differs from the Client ID in Keycloak |
| Error 500, log says the e-mail **isn't verified** | the user's *Email verified* is off in Keycloak; turn it on. Google users always have it |
| 403 for someone who has the role | the role is on another client, or `--allowed-role` / `--client-id` do not match the Client ID exactly; check with *Evaluate* (step 2) |
| Keycloak refuses someone with an access error before the app | they are not in `/Companies/Bindworks` (no `bindworks-user`), e.g. an account made by hand rather than through Google |
| The application opens without signing in | the `app` service still has a domain or a `ports:` entry |
| Endless redirects | the domain in Coolify is `http://`; with `--cookie-secure=true` the cookie is never sent back |
