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
- VM and container details: usage, performance charts, IP addresses, hardware and options
- Power actions (start, shut down, reboot, stop, reset, pause, resume, hibernate) with confirmation, hidden without the `VM.PowerMgmt` privilege
- Task tracking: progress of started actions, recent tasks of the server, task logs
- Consoles: a native VNC client for VMs (zoom, full screen, special keys, hardware keyboard) and a terminal for containers
- Configuration editing: processor, memory, firmware, disks (add, grow, detach, delete), CD/DVD drives, network devices, options, boot order and notes, with pending changes shown until the next restart
- Creating VMs (installation ISO, OS-specific defaults such as UEFI and TPM for Windows 11, disk, CPU, memory, network) and containers (templates, which can be downloaded from the app, root password or SSH keys, network and DNS)
- Demo mode with a built-in sample cluster, including working demo consoles

Next up: node and datacenter settings.

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

### Testing against a real server

Use a disposable Proxmox VE installation, for example a nested VM. Never a production server: the tools create and delete users and guests.

1. Copy `Config/TestServer.example.env` to `Config/TestServer.local.env` (ignored by git) and fill in the address and root credentials.
2. Run `python3 -I scripts/seed-test-server.py Config/TestServer.local.env`. It creates a TOTP user, a read-only user and a few VMs and containers, and appends the generated credentials to the env file. For the VM console test, attach an ISO with an operating system to VM 100 (the Alpine virt ISO works well) and start it.
3. Run the live tests:

```sh
cd Packages/ProxFleetKit
PROXFLEET_TEST_SERVER_ENV=$PWD/../../Config/TestServer.local.env swift test --filter LiveServerTests
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

## License

ProxFleet is free software, licensed under the GNU General Public License v3.0 or later.
