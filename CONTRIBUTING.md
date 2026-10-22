# Contributing to ProxFleet

Thanks for your interest in ProxFleet. Bug reports, ideas and pull requests are all welcome.

Before starting on a larger feature, please open an issue first, so we can agree on the approach before you spend time on it.

## Requirements

- Xcode 27 or newer
- iOS / iPadOS 26 Simulator or device
- For live tests only: a disposable Proxmox VE 8 or 9 installation

## Building

Open `ProxFleet.xcodeproj` and run the `ProxFleet` scheme. The Simulator needs no setup.

To run on a device, copy `Config/Signing.example.xcconfig` to `Config/Signing.local.xcconfig` and set your team ID and bundle ID prefix. The file is ignored by git.

The helper script builds the app and opens it in the Simulator:

```sh
scripts/run-simulator.sh --demo    # open the demo cluster, nothing is saved
scripts/run-simulator.sh --test    # sign in to the server from Config/TestServer.local.env
```

Set `SIMULATOR_DEVICE` to use another Simulator than the iPhone 17.

## Tests

Unit tests of the Swift package and UI tests of the app, which run against the demo cluster:

```sh
cd Packages/ProxFleetKit && swift test
xcodebuild test -project ProxFleet.xcodeproj -scheme ProxFleet -destination 'platform=iOS Simulator,name=iPhone 17'
```

### Testing against a real server

> [!WARNING]
> Use a disposable Proxmox VE installation, for example a nested VM. Never a production server: these tools create and delete users and guests.

1. Copy `Config/TestServer.example.env` to `Config/TestServer.local.env` (ignored by git) and fill in the address and root credentials.
2. Seed the server with a TOTP user, a read-only user and a few guests. The script appends the generated credentials to the env file.
   ```sh
   python3 -I scripts/seed-test-server.py Config/TestServer.local.env
   ```
   For the VM console test, attach an ISO with an operating system to VM 100 (the Alpine virt ISO works well) and start it.
   The SDN test needs dnsmasq on the node (`apt install dnsmasq`, then `systemctl disable --now dnsmasq`), as Proxmox requires for DHCP in SDN zones; the SDN routing test needs `frr-pythontools`, and the network test `openvswitch-switch`.
3. Run the live tests:
   ```sh
   cd Packages/ProxFleetKit
   PROXFLEET_TEST_SERVER_ENV=$PWD/../../Config/TestServer.local.env swift test --filter LiveServerTests
   ```

## Project layout

| Path | Contents |
| --- | --- |
| `ProxFleet/` | The SwiftUI app |
| `ProxFleetUITests/` | UI tests, run against the demo cluster |
| `Packages/ProxFleetKit/` | Everything below the UI, as a Swift package |
| `Config/` | Build settings and templates for local configuration |
| `scripts/` | Simulator and test server helpers |
| `docs/` | Architecture notes, screenshots and the README images |

The API client and the Proxmox VE models (`ProxmoxCore`, `PVEKit`, `ProxmoxConsole`) depend on Foundation only, so they could be reused on other platforms. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit together.

### README images

All images of the README (the banner and the Why ProxFleet, Features and Coming next cards) are generated. The banner is built from the screenshots in `docs/screenshots` (dark mode, demo mode, iPhone 17). After replacing them or changing the lists in the script, run:

```sh
python3 -I scripts/make-readme-art.py
```

## Guidelines

- **Keep demo mode working.** Every new screen needs matching routes in the demo cluster (`Packages/ProxFleetKit/Sources/DemoServer`). Demo mode is used by the UI tests and by App Review.
- **Follow the web interface.** Labels, defaults and validation should match the Proxmox VE web interface, so users feel at home in both.
- **Respect permissions.** Hide or lock actions the signed-in user has no privilege for, with an explanation instead of an error on tap.
- **Write in English.** Code, comments, commit messages and the user interface.
- **Never commit secrets.** No server addresses, passwords or tokens. Local files ending in `.local.*` are ignored by git for this reason.

## License

By contributing, you agree that your contributions are licensed under the [GNU General Public License v3.0 or later](LICENSE), like the rest of the project.
