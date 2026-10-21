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

## Configuration editing

Editors build a `GuestConfigUpdate` (keys to set, keys to delete, pending keys to revert) and `GuestDetail.apply` sends it with the `digest` of the configuration the editor was opened with. A changed digest makes the server refuse with "checksum mismatch", which becomes `ConfigUpdateError.conflict`; validation errors come back per parameter and are shown under the matching field.

- VMs update with `POST .../config` and return a task, which is awaited. Containers update with the synchronous `PUT`.
- `GET .../config` is called with `current=1`. Without it, Proxmox returns pending values, which made a running VM look already changed.
- Changes that cannot apply to a running VM (memory and CPU without hotplug, firmware) show up in `GET .../pending` until the next start. The Hardware tab lists them, with a way to revert them.
- Property-string values such as `net0` or `scsi0` are edited through drafts (`NetworkDeviceDraft`, `DiskOptionsDraft`, `PCIDeviceDraft`…) that keep options the form does not know.
- Option screens use `OptionsDraft`: the draft and the original are serialized the same way and only keys whose value differs are sent, so defaults the server stores differently never show up as changes.
- Rows the user lacks the privilege for show a lock and explain why; editors open read-only instead of disappearing.
- Every other key is reachable from All Settings, which builds its forms from the server's API schema. `apidoc.js` is fetched once per connection from `/pve-docs/api-viewer/apidoc.js` (no login needed) and only the guest configuration methods are kept. Types, enums, ranges and property-string keys pick the controls; keys that run code on the host (`args`) stay locked for anyone but root@pam.

## Creating guests

`VMCreationDraft` and `ContainerCreationDraft` (PVEKit) hold the creation forms and build the parameters of `POST /nodes/{node}/qemu` and `POST /nodes/{node}/lxc`. They start from the web interface's defaults; `applyDefaults(for:)` adjusts a VM to its OS type the way the web wizard does (Windows gets SATA and an Intel NIC, Windows 11 also OVMF, q35 and a TPM). Problems the app can see itself (ID range, names, missing storage or template, password rules) are listed by parameter name, the same keys the server uses for its validation errors, so both show under the same field.

- The forms are wizards with the pages of the web interface (`CreationWizard`). Each page says which request parameters it owns, so Next checks only that page's problems, and a server error after Create leads back to the page of the field.
- The ID comes from `GET /cluster/nextid`; the same call with `vmid` checks a typed ID.
- Creation returns a task. `ServerConnection.start` tracks it without reporting failures, since the form shows them; if the form closes while the task runs, `TaskCenter.reportFailure(of:)` hands the outcome back so a failure still shows up.
- Container templates come from storages with `vztmpl` content. `GET /nodes/{node}/aplinfo` lists what the node can download and `POST` to it starts the download.

## Snapshots, clones and deletion

`GuestLifecycle.swift` (PVEKit) has the requests and `CloneDraft`; `GuestDetail` runs them as tasks and reloads.

- `GET .../snapshot` lists the snapshots plus `current`, whose `parent` is the snapshot the running state is based on. `GuestSnapshot.tree` orders them like the web interface's tree. Descriptions come back with a trailing newline, which is trimmed.
- Only templates can be cloned linked (`full=0`); for other guests Proxmox always copies and rejects `full=0`. `storage` only applies to full clones, `snapname` only to guests that are not templates.
- Converting a VM to a template returns a task. A container returns `null` and converts in the background, so its configuration is polled until `template` is set.
- Deleting needs a stopped guest; Proxmox refuses a running one with an error message. The app asks the user to type the ID, as the web interface does, with `purge` and `destroy-unreferenced-disks` on by default.
- Migration is not done yet: there is no cluster to test it on.

## Backups

`Backups.swift` (PVEKit) has `BackupVolume`, `BackupDraft` and `RestoreDraft`; `GuestDetail.loadBackups` reads every active storage of the node with `backup` content in parallel, unlike the web interface, which shows one storage at a time.

- Backup Now is `POST /nodes/{node}/vzdump` with `remove=0`, so a manual backup never prunes older ones by the storage's retention settings. `notes-template` variables such as `{{guestname}}` are filled in by the server.
- Notes and protection change with `PUT .../storage/{storage}/content/{volume}`; the volume ID contains a slash and is escaped. Deleting a protected backup starts a task that fails, so the app disables it.
- `GET .../vzdump/extractconfig` returns the configuration as file text; VM backups add internal `#qmdump#` lines, which are hidden.
- Restore is the create call with `archive` (VMs) or `ostemplate` and `restore=1` (containers), plus `force` to replace the guest, which must be stopped. Containers need an explicit `storage`: without it Proxmox picks `local`, which usually cannot hold container volumes. A restore over the guest asks for confirmation first.
- Backup jobs (schedules) belong to the datacenter settings; file restore needs Proxmox Backup Server. Neither is done yet.

## Nodes

`NodeDetail` (FleetCore) loads `GET /nodes/{node}/status` and `rrddata` like `GuestDetail`; services, updates, the journal and tasks load when their screen opens. Guest and node screens share `DetailTabBar`.

- Node history uses `memused`/`memtotal` instead of the guests' `mem`/`maxmem`, plus `loadavg` and `iowait`; `RRDPoint` reads both.
- `apt/update`: POST refreshes the package index as a task, GET lists the updates found by the last refresh. Upgrading opens the node shell with `termproxy` `cmd=upgrade`, as the web interface's Upgrade button does, so the user confirms apt's prompt there.
- The system log comes from `GET .../journal?lastentries=N`, which answers gzip-compressed (URLSession unpacks it) and adds cursor lines at the start and end, which are dropped.
- Service actions return tasks named `srvrestart` and so on, with the service as object ID. Stopping `pveproxy`, `pvedaemon` or `pve-cluster` cuts off API access, so the app warns before it.
- Reboot and shutdown (`POST .../status`) answer right away; the node then goes offline.

### Node settings

- DNS: `PUT .../dns` requires `search` and removes every server it does not receive, so the app always sends all of them (`NodeDNS.parameters`), moving the remaining ones up.
- Hosts: `POST .../hosts` takes the whole file plus the `digest` it was read with; a changed file is refused like a guest configuration, and the latest version is loaded so saving again overwrites it.
- Time: only the time zone can be set. The list comes from the system's time zone names, which match `/usr/share/zoneinfo/zone.tab`.
- Network: changes go to `/etc/network/interfaces.new` and take effect with `PUT .../network` (a task running `ifreload`); `DELETE .../network` discards them. `GET .../network` reports the pending diff in `changes`, next to `data`, so `NetworkConfiguration` conforms to `EnvelopeDecodable` and decodes from the whole response body.
- `PUT .../network/{iface}` keeps settings it does not receive and needs `type`; cleared settings go in `delete`. `NetworkInterfaceDraft` serializes like `OptionsDraft` and only sends what changed. VLANs named like `vmbr0.20` take their parent and tag from the name. Proxmox itself checks for a second default gateway and ports used by another interface.
- Disks: `disks/list` with `include-partitions=1`, grouped under their disks by `parent`. `wearout` is a number or `N/A`; `used` is absent for unused disks. SMART returns attributes for ATA disks and plain text for NVMe and SAS. The LVM endpoint returns a tree (volume groups with physical volumes as children); ZFS pool details nest vdevs and sections (`logs`, `cache`) under `children`.
- Creating an LVM volume group, thin pool, ZFS pool or directory, initializing with GPT, wiping and removing are tasks. These need `Sys.Modify` on `/`, not only on the node. Only reading was verified on a real server, which has no spare disk; creation and removal are checked against demo mode.

## Consoles

Both consoles open a one-time proxy on the node and connect to it through `/nodes/.../vncwebsocket` over a WebSocket (subprotocol `binary`), with the same certificate pinning as API calls.

- **Containers and node shells** use `termproxy`. After `user:ticket\n` and the server's `OK`, input goes as `0:<bytes>:<data>`, resizes as `1:<cols>:<rows>:`, keep-alives as `2`, all in text frames. Output is raw terminal bytes, rendered by SwiftTerm. SwiftTerm is pinned to 1.11.x because later versions need a build plugin approval and the Metal toolchain.
- **VMs** use `vncproxy` with `generate-password`, then RFB 3.8 with VNC authentication (DES, implemented in `DES.swift` to keep the module portable). `VNCClient` asks for 32-bit BGRX pixels and the Raw, CopyRect and DesktopSize encodings, which QEMU always supports. All input goes through one queue so keys and clicks keep their order. Characters that need Shift on a US layout are sent with Shift held.

## Secrets

- Passwords (only when the user chooses to remember them) and tickets are stored in the Keychain with `WhenUnlockedThisDeviceOnly`.
- The server list (`servers.json`) contains no secrets.
- Developer test credentials live in `Config/TestServer.local.env`, which git ignores.

## Testing

- Package tests (`swift test`) cover the API client, decoding, authentication flows and the app domain, using `MockTransport` and the `DemoServer`.
- The demo server also answers console WebSockets: `termproxy` reaches a small fake shell and `vncproxy` an RFB server that draws a text console with Core Text, so both console clients run end to end without a Proxmox host. It serves its own reduced API schema for All Settings.
- UI tests run the app in the Simulator. Launch arguments: `-inMemory` (do not touch saved servers) and `-demo` (open the demo cluster).
- `PVEKitTests/Fixtures` holds responses recorded from a real Proxmox VE 9.2 node.
- `LiveServerTests` run against a real server when `PROXFLEET_TEST_SERVER_ENV` points to an env file: certificate pinning, login, renewal, TOTP and error formats. They are skipped otherwise.

Verified on Proxmox VE 9.2: `extjs` errors return HTTP 200 with `success: 0` and `status` (sometimes as a string). Requests without a valid ticket or CSRF token return HTTP 401 with an empty body. `DELETE` must not have a body. A second-factor challenge can be retried after a wrong code. Renewing a ticket within the same second returns the same ticket.

## Planned

- Using the API schema beyond guest configuration: generic forms for node, storage and datacenter settings.
- Task tracking (UPID) shared by all long-running actions.
- Compressed VNC encodings (ZRLE or Tight) for slow connections.
