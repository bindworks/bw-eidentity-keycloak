# Realm `bindworks`

The internal realm for Bindworks staff (https://id.bindworks.eu/realms/bindworks). This describes only what
differs from a freshly created Keycloak realm. State as of 2026-09-23, Keycloak 26.7.4.

## Who gets in

- **Staff sign in with Google Workspace.** The `google` identity provider is restricted to the `bindworks.eu`
  domain (*Hosted domain*), so only company Google accounts can use it. Settings: *Trust email* on,
  *Sync mode* `FORCE` (profile refreshed from Google on every login), *Store tokens* and *offline access* on.
  First login uses the standard `first broker login` flow (account is created automatically).
- **Every Google login is put into `/Companies/Bindworks`** by the IdP mapper *Assign Bindworks company*
  (hardcoded group). That group grants the realm role **`bindworks-user`**, which marks "one of us".
- **Nobody else can create an account:** self-registration and *Forgot password* are off. Other users
  (external people, the few password accounts) are created by an admin.

Leaving the company: the person can no longer sign in with Google (the domain check fails), but the Keycloak
user and its `/Companies/Bindworks` membership stay. Disable or delete the user to fully offboard.

- **Partner companies sign in through their own identity provider** and get the realm role **`idp-only-user`**
  (granted by their company group, today `/Companies/Iresoft`). Such users may sign in *only* through the
  provider: the browser flow refuses them both password and Email OTP. Removing a person in the partner's
  IdP is therefore enough to cut them off.

## Who may use which application

The browser flow **`browser for Bindworks`** ends with the sub-flow **non-Bindworks Application Role Check**,
which runs after a successful login and **denies access** when *all* of these hold:

- the client does **not** have the client scope `non-bindworks-users-allowed-application-oidc`,
- the client does **not** have the client scope `non-bindworks-users-allowed-application-saml`,
- the user does **not** have the role `bindworks-user`.

So users without `bindworks-user` can only use applications that carry one of those two (empty, marker-only)
client scopes. Today that is only **`dumplog-web`**; the SAML variant is not assigned to any client.
To open another application to outsiders, add `non-bindworks-users-allowed-application-oidc` (or `-saml`) to
that client as a default scope.

**Logins through an identity provider button do not reach this check**: after the redirect back, Keycloak runs
only the provider's *first login flow* and *post login flow*, not the rest of the browser flow. The top-level
flow **`post login - non-Bindworks check`** is a copy of the check (own config aliases, `… - postlogin`); set it as
*Post login flow* on every provider whose users do not get `bindworks-user`. Google does not need it (all its
users are `bindworks-user`).

## How people sign in (browser flow `browser for Bindworks`)

```
Cookie / Identity Provider Redirector
browser login for kimai
├─ Username Form                      username first (Google button on the same page)
├─ Authenticate
│  ├─ via Password      [CONDITIONAL] has a password and NOT idp-only-user                  -> password
│  ├─ via Email OTP     [CONDITIONAL] password not used, NOT bindworks-user, NOT idp-only-user -> code by e-mail
│  └─ deny otherwise    [CONDITIONAL] neither ran  -> "Přihlašte se pomocí některého vnějšího poskytovatele."
└─ TOTP                 [CONDITIONAL] user has TOTP configured     -> one-time code
non-Bindworks Application Role Check (see above)
```

- Staff without a password and `idp-only-user` users who type their username end up in the deny guard,
  which is what stops them from being let in with a username only.
- **Email OTP** is our fork `keycloak-2fa-email-authenticator` (execution config: 6 digits, 3 attempts,
  300 s). Wrong codes count towards brute-force protection. The e-mail uses the email theme
  `email-code-theme` and the texts below.
- The flow's conditions ("sub-flow executed") reference the sub-flows **by name** (`via Password`,
  `via Email OTP`). Renaming a sub-flow breaks the flow; an unconfigured condition lets people in without
  a second step. Test with a user of each kind after any change.
- **`email-code-theme` requires email authenticator ≥ 1.1.1** (image ≥ 26.8.2-2). Up to 1.1.0 the plugin
  shipped that theme's `theme.properties` at `theme/email-code-theme/theme.properties`, one directory above
  where Keycloak reads it — it reads one per theme **type**, at `theme/<name>/<type>/theme.properties`, as
  every built-in theme does. So `parent=keycloak` never applied and the theme had **no parent**: the OTP code
  mail worked, because that template is the theme's own, and every mail inherited from `base` failed with
  `TemplateNotFoundException` — password reset, e-mail verification, execute-actions, identity-provider link,
  org invites, the `event-*` notices. That includes `email-test`, so the admin console's SMTP **Test
  connection** button was a *false negative* in this realm: it died on the template before opening a socket
  and said nothing about the relay. `zscanner` had the same setting and the same breakage. Never a Keycloak
  regression — identical on 26.7.4 with a byte-identical jar, and broken since the plugin was introduced.
  If a future image ever pins an older plugin, this realm's mail silently narrows to the OTP code again.

## Application-specific roles (groups)

Access inside the applications is managed with groups; the groups grant client roles:

| Group | Grants | Used by |
|---|---|---|
| `/Companies/Bindworks` | realm role `bindworks-user` | the access check above |
| `/Companies/Iresoft` | realm role `idp-only-user` | no password / Email OTP (see the flow above) |
| `/Project Developers/*-devs` (and `admin-devs`) | `dumplog-web` roles `*-expander` | dumplog-web (which projects a developer can see) |
| `/Kimai/Kimai_SuperAdmins`, `_Admins`, `_Teamleads` | `kimai` roles `Kimai-Role-*` | Kimai (SAML role list) |
| `/oo/*/admins` | – (membership only) | presumably OpenObserve organisations, read from the `groups` claim |
| `/Apps/*` (or any group) | `<app>` role `access` | standalone Coolify apps behind their own oauth2-proxy, see [STANDALONE-APP.md](STANDALONE-APP.md) |
| `/Project Developers/*-devs` | `demo-annapurna` roles `*-prototype` (and `all` on one group) | static prototypes on `*.demo.bindworks.eu`, see [DEMO-PROTOTYPE.md](DEMO-PROTOTYPE.md) |

Adding an application and deciding in Keycloak who may open it: [STANDALONE-APP.md](STANDALONE-APP.md) for a
standalone app, [DEMO-PROTOTYPE.md](DEMO-PROTOTYPE.md) for a prototype on `*.demo.bindworks.eu`.

The client scope `groups` (group membership claim) is assigned to `openobserve.bind.works` and `tudoo`;
Kimai (SAML) gets `AuthnContextClassRef` and its own role and user-property mappers.

## Other realm settings that differ from defaults

| Setting | Value |
|---|---|
| Display name | `Bindworks` (used in the e-mail subject and the browser title) |
| Login theme / Email theme | `bindworks` (this repo, `themes/bindworks`) / `email-code-theme` (from the email OTP plugin, **needs plugin ≥ 1.1.1** — see the authentication-flow notes above) |
| Localization | on, `cs` (default) and `en` |
| Realm overrides (cs + en) | `loginAccountTitle` (Přihlášení do / Sign in to Bindworks), `emailCodeSubject`, `emailCodeBody` |
| SMTP | `smtprelay:587` (no auth, no TLS), from `serviceadmin@bindworks.eu` |
| Brute force detection | on, lockout after 10 failures, temporary (1 min, growing to 15 min) |
| User registration / Forgot password / Remember me | off / off / off |

The SMTP host changed on 2026-11-17: it was `relay-mail.smtprelay.svc.cluster.local:587` while Keycloak ran
on AKS, and that name does not resolve from the Contabo host it runs on now, so mail failed on DNS until the
realm was repointed. `smtprelay` is reachable only because the `022-keycloak` stack joined the `mail` docker
network — see `stacks/022-keycloak/compose.yaml` in bw-ops-prod. Changing `realm_smtp_config` in the database
is not enough on its own; the running server serves the cached value until the container is recreated.

Sessions, tokens, events (off), required actions and the user profile are Keycloak defaults.

## The login theme is shared with other realms

`themes/bindworks` is not specific to this realm — other realms use it as their login theme
(e.g. `zscanner` / ZUNI Cloud). It intentionally keeps the Bindworks branding for all of them:
the wordmark in the top bar (`resources/img/bindworks-logo.svg`) and the **Kontakt** button that
`resources/js/header.js` adds, which links to `serviceadmin@bindworks.eu`. A realm that needs its
own logo or contact would need a child theme (`parent=bindworks`), not a change in this one.

Three things to know before pointing a realm with more identity providers at it:

* **Provider logos.** Keycloak's base template draws a built-in SVG logo for a provider only when
  its icon classes are empty; otherwise it renders `<span class="<icon classes>">` and expects a
  Font Awesome glyph, which PatternFly 5 cannot supply for brand icons (it ships only the *solid*
  font) — the button then shows a missing-glyph box. The Apple provider jar returns `fa fa-apple`,
  so the theme overrides it with `kcLogoIdP-apple=bw-idp bw-idp-apple` in `theme.properties` and
  draws `resources/img/idp/apple.svg` from `bindworks.css`. A further provider needs the same three
  pieces: the SVG in `resources/img/idp/`, the `kcLogoIdP-<alias>` line, and one `bw-idp-<name>`
  rule; leaving the value blank instead gives Keycloak's own logo for the providers it knows. The
  icon classes are looked up as `kcLogoIdP-<alias>`, then `kcLogoIdP-<provider id>`, then the
  provider's own value. As a last resort `bindworks.css` suppresses any leftover `fa-*` glyph,
  leaving a text-only button.
* **Four or more providers switch to a grid.** Keycloak then renders the button list as a
  two-column PatternFly grid (`pf-v5-l-grid pf-m-all-6-col-on-sm`) instead of full-width pills.
  `bindworks.css` styles that case separately: inside `.pf-v5-l-grid` the logo stops being pinned
  28 px from the left edge and flows inline next to the label (which ellipsises), because the
  narrow buttons would otherwise have logo and text overlap.
* **Button labels and modifier classes are the base theme's, and they move between releases.**
  26.8 renamed the social button modifier from `pf-m-secondary` to `pf-m-tertiary`, stopped
  inlining the logos as `<svg>` in favour of `<img>`/`<picture>`, replaced the "Or sign in with"
  footer band with a `.kc-login-divider`, and started wrapping every label in
  `msg("signInWithProvider", displayName)`. The theme therefore matches social buttons without
  naming the modifier, positions `> svg, > img, > picture` alike, and overrides
  `signInWithProvider={0}` in `messages/messages_{en,cs}.properties` — otherwise the Apple
  provider, whose display name is "Sign in with Apple", would read "Sign in with Sign in with
  Apple". Re-check these four points on the next major upgrade.
