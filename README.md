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
- Task tracking: progress of started actions, recent tasks of the server, task logs, stopping running tasks
- Consoles: a native VNC client for VMs (Tight compression with a data saver, trackpad or touch mouse, Ctrl/Alt/Shift/Win and shortcuts such as Ctrl+Alt+Del, typing the clipboard, hardware keyboards as physical keys, mouse and trackpad on iPad, full screen in landscape) a terminal for containers, and VM serial ports
- Configuration editing: processor, memory, firmware, disks (add with every option of the web interface or import a disk image, grow, detach, delete), CD/DVD drives (ISO image or the host's drive), network devices, devices such as PCI (with vGPU types and ID overrides), USB, EFI disk and TPM, container device passthrough, options, boot order and notes, with pending changes shown until the next restart
- Creating VMs (installation ISO or the host's drive, OS-specific defaults such as UEFI and TPM for Windows 11, x86 or emulated ARM, new or imported disks, CPU, memory, network devices) and containers (templates, which can be downloaded from the app, root password or SSH keys, mount points, network devices and DNS), with the web interface's advanced options behind an Advanced switch
- Snapshots (take with or without RAM, roll back, describe, delete), cloning (full or linked from templates, from a snapshot, in another image format), converting to a template and deleting guests
- Backups: back up now (mode, compression, notes, protection, pruning, sendmail notifications), list from all backup storages, notes and protection, configuration in the backup, restore over the guest or as a new one (with live restore from a Proxmox Backup Server, bandwidth limit and overrides of name, CPU, memory and privilege level), delete
- Nodes: status, usage and history, notes, shell, package updates (refresh, list, upgrade in the shell), package changelogs, services, system log, tasks, system report, bulk start, shutdown and hibernate of guests, reboot and shutdown, wake on LAN for offline nodes
- Node settings: network interfaces (bridges, bonds, VLANs; pending changes with apply and revert), DNS, hosts, time zone and options (wake on LAN, start-at-boot delay, ballooning target, location)
- Disks: list with partitions, SMART values, wipe and GPT initialization; LVM, LVM-thin, ZFS (with pool status) and directories, created on unused disks or removed
- APT repositories (status, enable and disable, add standard ones) and certificates (view, upload a custom one, remove it)
- Storage: usage with its history and content by type (ISO images, templates, backups, VM disks, CT volumes, snippets, import), download from a URL with an optional checksum and decompression (also from the VM wizard), container templates pulled from OCI registries, backups restored as new guests (also of deleted guests) and pruned by retention rules, OVA, OVF and ESXi guests imported as VMs, disk images imported into a VM, delete
- Datacenter storage: add, edit, disable, restrict to nodes and remove storage definitions (Directory, LVM, also on iSCSI LUNs, LVM-Thin, Btrfs, NFS, SMB/CIFS, iSCSI, CephFS, RBD, ZFS over iSCSI, ZFS, Proxmox Backup Server with encryption keys, ESXi), with scans for exports, shares, targets, datastores and pools, preallocation, snapshots as volume chains, and backup retention
- Backup jobs: schedules with a preview of the next runs, all guests, selected ones, all except some, or a pool, retention, notifications, advanced options (bandwidth limit, zstd threads, IO workers, fleecing, PBS change detection), the disks each job includes, Run Now, and the guests no job covers
- Pools: create, nest, comment, add and remove guests and storage, and permissions on a pool
- SDN: Simple, VLAN, QinQ and VXLAN zones, VNets, subnets with gateway, SNAT and DHCP ranges, pending changes with apply and revert, zone status, VNet firewalls and the addresses the built-in IPAM handed out
- Resource mappings: PCI devices (single functions, whole devices, several devices as a pool, mediated devices), USB devices by ID or port, and directories for virtiofs, with the checks the server reports
- Datacenter bulk start, shutdown and hibernate of guests on all nodes, and the cluster log
- Users & Permissions: users (create, edit, disable, expiry, password), API tokens with the secret shown once, groups, custom roles, and permissions on paths for users, groups and tokens, two-factor authentication (authenticator apps with a QR code, recovery keys, unlocking) and realms (LDAP, Active Directory, OpenID Connect, sync)
- Notifications (sendmail, SMTP, Gotify and webhook targets with test sending, matchers by severity, field and time) and datacenter options (keyboard layout, guest ID range, MAC prefix, migration and replication, bandwidth limits, tags and their colors, HA policy, scheduler, rebalancing and fencing, WebAuthn and U2F, location, proxy, notes)
- Firewall for the datacenter, nodes and guests: turn it on and off, rules (direction, action, macros, protocols, ports, ICMP types, addresses with aliases and IP sets, interface, log level), reordering, security groups, aliases, IP sets with excluded entries, all options, and the firewall log of nodes and guests
- Demo mode with a built-in sample cluster, including working demo consoles

Next up: ACME, HA and migration between cluster nodes.

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
2. Run `python3 -I scripts/seed-test-server.py Config/TestServer.local.env`. It creates a TOTP user, a read-only user and a few VMs and containers, and appends the generated credentials to the env file. For the VM console test, attach an ISO with an operating system to VM 100 (the Alpine virt ISO works well) and start it. The SDN test needs dnsmasq on the node (`apt install dnsmasq`, then `systemctl disable --now dnsmasq`), as Proxmox requires for DHCP in SDN zones.
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
