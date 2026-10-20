# Architecture

## Goals

- Native iOS look and behaviour, iPhone and iPad.
- Grow towards the feature set of the Proxmox web interface without rewriting the foundations.
- Keep everything below the UI portable, so an Android version could reuse it later.
- Share the plumbing between Proxmox VE and Proxmox Backup Server, which use the same authentication.

## Modules

```
ProxFleet (app)          SwiftUI screens, navigation, launch options
└─ FleetCore             saved servers, Keychain, live connections, add-server flow
   ├─ PVEKit             Proxmox VE endpoints and models
   ├─ ProxmoxURLSession  URLSession transport with certificate pinning (Apple only)
   ├─ DemoServer         in-memory fake cluster for demo mode, previews and tests
   └─ ProxmoxCore        API client, authentication, errors, decoding (Foundation only)
```

`ProxmoxCore` and `PVEKit` depend on Foundation only. Anything Apple-specific (Security, CryptoKit, Keychain, SwiftUI) lives in `ProxmoxURLSession`, `FleetCore` or the app.

## Talking to Proxmox

- **API format.** Requests go to `/api2/extjs/...`, the format the web interface uses. Errors come back in the body (`success`, `status`, `message`, `errors`), so the app can show the server's message and map validation errors to form fields.
- **Authentication.** `ProxmoxSession` (an actor) logs in with `POST /access/ticket`. The ticket goes in the `PVEAuthCookie` cookie, and write requests carry the `CSRFPreventionToken` header. The ticket is renewed after 15 minutes, as the web interface does, and expires after two hours.
- **Two-factor authentication.** When the first login step returns a partial ticket (`PVE:!tfa!…`), the embedded challenge tells which factors are available. TOTP, Yubico OTP and recovery keys are supported. WebAuthn needs a browser bound to the server's domain and is not possible in a native app.
- **Certificates.** Publicly trusted certificates are accepted normally. Otherwise the user sees the SHA-256 fingerprint and can trust it. The fingerprint is stored with the server and checked on every connection, including WebSockets later.
- **Loose typing.** Proxmox sometimes sends numbers as strings and booleans as `0`/`1`. Models decode with the `lossy*` helpers from `LossyDecoding.swift`.

## Servers and clusters

A saved server (`ServerProfile`) is either a standalone node or a cluster. In both cases the app works with a `ClusterSnapshot`, built from `/cluster/status` and `/cluster/resources`. A standalone node is simply a cluster with one node, so screens have a single code path.

A profile can hold several addresses. Tickets are valid on every node of a cluster, so when one node is unreachable the connection moves on to the next address without signing in again. When the user adds a node of a cluster that is already saved, the app offers to add the address to the existing entry.

Each saved server has its own `ServerConnection`, so several servers can be signed in at the same time.

## Secrets

- Passwords (only when the user chooses to remember them) and tickets are stored in the Keychain with `WhenUnlockedThisDeviceOnly`.
- The server list (`servers.json`) contains no secrets.
- Developer test credentials live in `Config/TestServer.local.env`, which git ignores.

## Testing

- Package tests (`swift test`) cover the API client, decoding, authentication flows and the app domain, using `MockTransport` and the `DemoServer`.
- UI tests run the app in the Simulator. Launch arguments: `-inMemory` (do not touch saved servers) and `-demo` (open the demo cluster).
- Fixtures in tests follow the API documentation for now. They will be replaced by responses recorded from a real test server.

## Planned

- Generating endpoint definitions and parameter types from the Proxmox API schema (`apidoc.js`), and a generic form that can edit any endpoint from its schema. Hand-made screens for the important flows, generated forms for everything else.
- Task tracking (UPID) shared by all long-running actions.
- Console: SwiftTerm for container and node shells, noVNC for virtual machines at first.
