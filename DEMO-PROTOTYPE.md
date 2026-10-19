# Demo prototype behind Keycloak (`*.demo.bindworks.eu`, shared gate)

For our prototypes: static sites someone put together in HTML, CSS and JS, hosted in Coolify on
`<name>.demo.bindworks.eu` and visible only to the people we pick in Keycloak. One gate serves every
prototype; once it is set up, a new prototype is its own Git repository, a role and a few fields in the Coolify
dashboard, with nothing to write.

For an application that runs on its own (a backend, its own login, API callers, its own domain) use
[STANDALONE-APP.md](STANDALONE-APP.md) instead: it gets its own oauth2-proxy, shares no cookie, and needs
no labels managed by hand.

## How it works

One oauth2-proxy, deployed once, decides for every prototype. It never serves pages itself: Coolify's proxy
(Traefik) asks it about every request before passing the request on to the prototype.

```
browser ── https://onboarding.demo.bindworks.eu/app.js ──> Traefik (Coolify proxy)
                                                             │ middleware demo-onboarding asks:
                                                             │ GET http://oauth2-proxy-…:4180/?allowed_groups=role:demo-annapurna:onboarding,role:demo-annapurna:all
                                                             ▼
                                                          oauth2-proxy (the gate)
     no cookie ........................................ 302 → sign in at id.bindworks.eu, then back to the prototype
     cookie, role demo-annapurna:onboarding or :all ... 202 → Traefik serves the file (nginx in the prototype's container)
     cookie, neither role ............................. 403
```

- **Signing in** happens once for all prototypes: the callback is `https://auth.demo.bindworks.eu/oauth2/callback`
  and the cookie is set for `.demo.bindworks.eu`. The role is still checked for each prototype separately,
  because each prototype's middleware asks with its own `allowed_groups`.
- **Who may see what** is the Keycloak client `demo-annapurna`, named after Annapurna, our self-hosted Coolify
  instance: one client role per prototype (`onboarding`), plus `all` for people who see every prototype.
  Assigned like any other role, best through groups.
- **Bindworks staff only.** The realm already refuses everyone without `bindworks-user` on a client that lacks
  the `non-bindworks-users-allowed-application-*` scope ([REALM-BINDWORKS.md](REALM-BINDWORKS.md)); never add
  it to `demo-annapurna`.
- **Revocation within about a minute.** oauth2-proxy refreshes the tokens at Keycloak every minute
  (`--cookie-refresh=1m`) and rebuilds the roles from the new ones (oauth2-proxy v7.15.4, `redeemRefreshToken`
  and `extractRoles`). A removed role gives 403 on the next request; a disabled user is sent to sign in and
  Keycloak refuses them. A newly granted role starts working the same way, within a minute.
- **Fails closed.** If Traefik cannot reach the gate, or a label names a middleware that does not exist, the
  prototype returns an error, never the page.
- **Only prototypes that carry the label are gated.** Anything else on `*.demo.bindworks.eu` stays as public
  as it is today.

The example prototype below is `onboarding`; replace it everywhere.

## One-time setup

### Keycloak: client `demo-annapurna`

*Clients → Create client*

1. General settings: Client type `OpenID Connect`, Client ID `demo-annapurna`, Name `Demo prototypes (Annapurna)`,
   Description `Prototypes on *.demo.bindworks.eu. One role per prototype; all = every prototype.` → Next
2. Capability config: Client authentication **On**, Authorization Off, only **Standard flow** ticked,
   PKCE Method **`S256`** → Next
3. Login settings: Root URL and Home URL `https://auth.demo.bindworks.eu`, Valid redirect URIs
   `https://auth.demo.bindworks.eu/oauth2/callback`, the rest empty → Save

Then:

- PKCE Method, if the client was created without it: *Settings → Capability config* → `S256` → Save. (It
  makes Keycloak insist on PKCE; oauth2-proxy uses it either way because of `--code-challenge-method=S256`.)
- *Client scopes → `demo-annapurna-dedicated` → Configure a new mapper → Audience*: Name `audience`, Included Client
  Audience `demo-annapurna`, Add to ID token and Add to access token **On** → Save (oauth2-proxy's Keycloak guide
  asks for it).
- *Roles → Create role*: `all`, Description `Sees every demo prototype`.
- *Credentials*: copy the Client secret into the password manager.

### DNS

`*.demo.bindworks.eu` already points at the Coolify server for the prototypes; `auth.demo.bindworks.eu`
falls under it. Coolify gets each host its own certificate on the first deploy.

### Coolify: the gate

New resource → *Docker Compose Empty*, name `demo-oauth-keycloak-gate`:

```yaml
services:
  oauth2-proxy:
    # Same version as bw-infra-openobserve, where the 1-minute revocation was measured.
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.15.4
    restart: unless-stopped
    environment:
      OAUTH2_PROXY_CLIENT_SECRET: ${KEYCLOAK_CLIENT_SECRET}
      OAUTH2_PROXY_COOKIE_SECRET: ${OAUTH2_PROXY_COOKIE_SECRET}
    command:
      - --provider=keycloak-oidc
      - --oidc-issuer-url=https://id.bindworks.eu/realms/bindworks
      - --client-id=demo-annapurna
      - --code-challenge-method=S256
      - --redirect-url=https://auth.demo.bindworks.eu/oauth2/callback
      - --email-domain=*
      # one sign-in for every prototype, and no redirects outside .demo.bindworks.eu
      - --cookie-domain=.demo.bindworks.eu
      - --whitelist-domain=.demo.bindworks.eu
      - --cookie-secure=true
      # Re-check Keycloak every minute; without it removing a role does nothing for 7 days.
      # Do NOT add --session-cookie-minimal: it drops the refresh token and turns this off.
      - --cookie-refresh=1m
      - --cookie-expire=4h
      # Only answers Traefik: 202 = let through, 302 = sign in first, 403 = no role.
      # No --allowed-role here: each prototype's middleware says which roles it accepts.
      - --upstream=static://202
      - --reverse-proxy=true
      - --skip-provider-button=true
      - --http-address=0.0.0.0:4180
```

1. **Environment Variables**: `KEYCLOAK_CLIENT_SECRET` (from Keycloak) and `OAUTH2_PROXY_COOKIE_SECRET`:
   ```bash
   openssl rand -base64 32 | tr -- '+/' '-_'
   ```
2. **Domains** of the `oauth2-proxy` service: `https://auth.demo.bindworks.eu:4180`.
3. **General → Network → Network attachment: *Connect to the predefined Coolify network*** (not *Use the
   stack network only*; older Coolify versions call it *Advanced → Connect to predefined network*), then
   *Save changes*. Traefik must reach the gate directly, not through its public address (that would lose the
   original host, and after sign-in people would land on the gate).
4. Deploy, then note the gate's internal hostname. Coolify names it `oauth2-proxy-<uuid>`, where `<uuid>` is
   the last part of the resource's URL in the dashboard (`…/service/<uuid>`); check on the server:
   ```bash
   docker ps --format '{{.Names}}' | grep oauth2-proxy
   ```
   Every middleware below uses `http://<that name>:4180/`. On Annapurna it is
   **`oauth2-proxy-i7dxux7qjhdgu7iod9xve8bi`**. If the gate resource is ever recreated, the uuid changes:
   update it in every `demo-*.yaml` file, or every gated prototype answers `500`.

## Adding a prototype

About five minutes, all in dashboards.

1. **Keycloak**: *Clients → demo-annapurna → Roles → Create role* `onboarding`, Description saying what it is and who
   asked for it.
2. **Coolify, the middleware**: *Servers → (server) → Proxy → Dynamic Configurations → Add*, file name
   `demo-onboarding.yaml`:
   ```yaml
   http:
     middlewares:
       demo-onboarding:
         forwardAuth:
           address: "http://oauth2-proxy-i7dxux7qjhdgu7iod9xve8bi:4180/?allowed_groups=role:demo-annapurna:onboarding,role:demo-annapurna:all"
   ```
   Traefik picks it up without a restart. `role:<client>:<role>` is how oauth2-proxy names a Keycloak
   client role; list every role that may see the prototype, comma-separated.
3. **Coolify, the site**: each prototype is its own Coolify application from its own Git repository.
   New resource → the prototype's repository → Build pack **Static**, Base Directory `/` (or the folder
   holding `index.html`, if it is not at the root).
   Domain `https://onboarding.demo.bindworks.eu` (it must be `https://`).
   The Static build pack serves the committed files with nginx and runs no build. A prototype with a build
   step (Vite, `npm run build`) uses Nixpacks or Railpack instead, Site type Static, Publish Directory `dist`.
4. **Coolify, the label — before the first Deploy**, otherwise the prototype is public until the next one:
   *General → Container labels → Label management: Managed manually*, then find the line
   `traefik.http.routers.https-0-<uuid>.middlewares=gzip` and append the middleware:
   ```
   traefik.http.routers.https-0-<uuid>.middlewares=gzip,demo-onboarding@file
   ```
   (If the line is not there, add it with `demo-onboarding@file` alone.) Save, Deploy.
5. **Grant it**: assign `demo-annapurna` `onboarding` to the people or group who should see it (*Groups → (group) →
   Role mapping → Assign role → Filter by clients*). Everyone with `demo-annapurna` `all` sees it already.
6. **Check**, below, then send the link.

**A prototype that is already deployed** gets steps 1, 2, 4 (with *Redeploy* instead of the first Deploy)
and 5. Until the redeploy it stays public, as before.

With labels *managed manually* Coolify no longer rewrites them. Changing the domain later: switch back to
*Managed by Coolify*, change it, switch to manual again and re-append the middleware.

## Check

1. Nobody signed in:
   ```bash
   curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://onboarding.demo.bindworks.eu/
   ```
   Expect `302 https://id.bindworks.eu/realms/bindworks/protocol/openid-connect/auth?...`.
   A `200` means the label is missing: the prototype is public.
2. Someone **with** `onboarding` or `all` signs in and sees it.
3. Someone **without** them gets `403 Forbidden`. If they get in, the middleware's `?allowed_groups=` is
   missing or not reaching the gate, and the prototype is open to every Bindworks account.

## Removing a prototype

Delete the Coolify application, the dynamic configuration file `demo-onboarding.yaml` and the Keycloak role
`onboarding` (which also removes it from every group and person). Taking access away from one person is
just removing the role or the group membership.

## Keep in mind

- **The gate decides who sees the files, not what is in them.** Every viewer can read all of the JS, so a
  prototype must not contain API keys, passwords or real customer data.
- **One cookie for all of `.demo.bindworks.eu`.** The browser sends it to every host under it, gated or not.
  Fine for static prototypes; an application with a backend or its own logins does not belong under
  `demo.bindworks.eu` (use [STANDALONE-APP.md](STANDALONE-APP.md) on another domain).
- **The gate down means every gated prototype is down** (they answer with an error, not the page). Nothing
  else depends on it.
- **Signing out**: `https://auth.demo.bindworks.eu/oauth2/sign_out` drops the cookie, but the next visit
  signs in again silently through the Keycloak session. To really sign out, sign out of Keycloak.
- The prototype's own `fetch` calls get `401` instead of a redirect once the session is gone (oauth2-proxy
  does this for requests that ask for JSON); reloading the page signs in again.

## Troubleshooting

The gate logs every decision: Coolify → `demo-oauth-keycloak-gate` → *Logs*. Traefik's own errors are under
*Servers → (server) → Proxy → Logs*.

| Symptom | Cause |
|---|---|
| The prototype opens without signing in | label not appended, not saved or not redeployed; or the domain is `http://` |
| Everyone with a Bindworks account gets in | the middleware address has no `?allowed_groups=…` |
| `404` on every page of the prototype | the label names a middleware Traefik does not know: file or name differ, or `@file` is missing |
| `500` / bad gateway on every page | Traefik cannot reach the gate: wrong hostname in the address, or *Network attachment* is *Use the stack network only* |
| After signing in people land on `auth.demo.bindworks.eu` | the prototype's domain is not under `.demo.bindworks.eu`, or the address points at the gate's public URL |
| Keycloak: *Invalid parameter: redirect_uri* | *Valid redirect URIs* differ from `--redirect-url` |
| `403` for someone who has the role | role created on another client, or its name differs from the address (`role:demo-annapurna:onboarding`); a newly granted role needs up to a minute |
| Deep links of a single-page app give `404` | nginx has no SPA fallback: *General → generate the nginx configuration*, add it, redeploy |
