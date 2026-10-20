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

## Tasks and guest details

Most actions return a task ID (UPID) instead of a result. `TaskCenter`, owned by each `ServerConnection`, polls `/nodes/{node}/tasks/{upid}/status` until the task stops (every 0.5 s at first, slower later), refreshes the snapshot afterwards and reports failures with the server's `exitstatus`. A screen that shows the outcome itself starts the task with `reportsFailure: false`, so the failure is not shown twice.

`GuestDetail` loads status, configuration, performance history (`rrddata`), IP addresses (QEMU guest agent or container interfaces), the user's privileges on `/vms/{vmid}` and recent tasks in parallel. A paused VM reports `status: running` with `qmpstatus: paused`, so `GuestStatus.powerState` combines both. Power actions are offered according to state and the `VM.PowerMgmt` privilege, as in the web interface.

## Secrets

- Passwords (only when the user chooses to remember them) and tickets are stored in the Keychain with `WhenUnlockedThisDeviceOnly`.
- The server list (`servers.json`) contains no secrets.
- Developer test credentials live in `Config/TestServer.local.env`, which git ignores.

## Testing

- Package tests (`swift test`) cover the API client, decoding, authentication flows and the app domain, using `MockTransport` and the `DemoServer`.
- UI tests run the app in the Simulator. Launch arguments: `-inMemory` (do not touch saved servers) and `-demo` (open the demo cluster).
- `PVEKitTests/Fixtures` holds responses recorded from a real Proxmox VE 9.2 node.
- `LiveServerTests` run against a real server when `PROXFLEET_TEST_SERVER_ENV` points to an env file: certificate pinning, login, renewal, TOTP and error formats. They are skipped otherwise.

Verified on Proxmox VE 9.2: `extjs` errors return HTTP 200 with `success: 0` and `status` (sometimes as a string). Requests without a valid ticket or CSRF token return HTTP 401 with an empty body. `DELETE` must not have a body. A second-factor challenge can be retried after a wrong code. Renewing a ticket within the same second returns the same ticket.

## Planned

- Generating endpoint definitions and parameter types from the Proxmox API schema (`apidoc.js`), and a generic form that can edit any endpoint from its schema. Hand-made screens for the important flows, generated forms for everything else.
- Task tracking (UPID) shared by all long-running actions.
- Console: SwiftTerm for container and node shells, noVNC for virtual machines at first.
