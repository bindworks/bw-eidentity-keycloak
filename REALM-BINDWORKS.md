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

## Application-specific roles (groups)

Access inside the applications is managed with groups; the groups grant client roles:

| Group | Grants | Used by |
|---|---|---|
| `/Companies/Bindworks` | realm role `bindworks-user` | the access check above |
| `/Companies/Iresoft` | realm role `idp-only-user` | no password / Email OTP (see the flow above) |
| `/Project Developers/*-devs` (and `admin-devs`) | `dumplog-web` roles `*-expander` | dumplog-web (which projects a developer can see) |
| `/Kimai/Kimai_SuperAdmins`, `_Admins`, `_Teamleads` | `kimai` roles `Kimai-Role-*` | Kimai (SAML role list) |
| `/oo/*/admins` | – (membership only) | presumably OpenObserve organisations, read from the `groups` claim |

The client scope `groups` (group membership claim) is assigned to `openobserve.bind.works` and `tudoo`;
Kimai (SAML) gets `AuthnContextClassRef` and its own role and user-property mappers.

## Other realm settings that differ from defaults

| Setting | Value |
|---|---|
| Display name | `Bindworks` (used in the e-mail subject and the browser title) |
| Login theme / Email theme | `bindworks` (this repo, `themes/bindworks`) / `email-code-theme` (from the email OTP plugin) |
| Localization | on, `cs` (default) and `en` |
| Realm overrides (cs + en) | `loginAccountTitle` (Přihlášení do / Sign in to Bindworks), `emailCodeSubject`, `emailCodeBody` |
| SMTP | `relay-mail.smtprelay.svc.cluster.local:587`, from `serviceadmin@bindworks.eu` |
| Brute force detection | on, lockout after 10 failures, temporary (1 min, growing to 15 min) |
| User registration / Forgot password / Remember me | off / off / off |

Sessions, tokens, events (off), required actions and the user profile are Keycloak defaults.
