# ProxFleet

A native iOS and iPadOS app for managing Proxmox VE servers and clusters, with Proxmox Backup Server support planned.

ProxFleet signs in the same way the web interface does: user name, password and realm (`pam`, `pve`, …), with optional two-factor authentication. No API tokens needed.

> ProxFleet is an independent project and is not affiliated with Proxmox Server Solutions GmbH. Proxmox is a registered trademark of Proxmox Server Solutions GmbH.

## Status

Early development. What works now:

- Adding servers, including the confirmation of self-signed certificates (trust on first use)
- Sign-in with password and realm, TOTP, Yubico OTP or recovery keys
- Standalone nodes and clusters, with several saved servers and automatic failover between cluster nodes
- Cluster overview: nodes, resource usage, virtual machines and containers
- Demo mode with a built-in sample cluster

Next up: virtual machine details, power actions, console, configuration editing and creation.

## Requirements

- Xcode 27 or newer
- iOS / iPadOS 26 or newer
- Proxmox VE 8 or 9

## Building

Open `ProxFleet.xcodeproj` and run the `ProxFleet` scheme. No setup is needed for the Simulator.

To run on a device, copy `Config/Signing.example.xcconfig` to `Config/Signing.local.xcconfig` and set your team ID and bundle ID prefix. That file is ignored by git.

```sh
scripts/run-simulator.sh --demo    # build and open the demo cluster in the Simulator
scripts/run-simulator.sh --test    # sign in to the server from Config/TestServer.local.env
```

## Tests

```sh
cd Packages/ProxFleetKit && swift test
xcodebuild test -project ProxFleet.xcodeproj -scheme ProxFleet -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Project layout

| Path | Contents |
| --- | --- |
| `ProxFleet/` | SwiftUI app |
| `ProxFleetUITests/` | UI tests |
| `Packages/ProxFleetKit/` | Everything below the UI, as a Swift package |
| `Config/` | Build settings and local configuration templates |
| `docs/` | Architecture notes |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit together.
