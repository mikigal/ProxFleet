// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProxFleetKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ProxmoxCore", targets: ["ProxmoxCore"]),
        .library(name: "ProxmoxURLSession", targets: ["ProxmoxURLSession"]),
        .library(name: "PVEKit", targets: ["PVEKit"]),
        .library(name: "FleetCore", targets: ["FleetCore"]),
        .library(name: "DemoServer", targets: ["DemoServer"]),
    ],
    targets: [
        // Portable: Foundation only. No Apple-specific frameworks, so it can be reused on other platforms.
        .target(name: "ProxmoxCore"),
        // Apple transport: URLSession with trust-on-first-use certificate pinning.
        .target(name: "ProxmoxURLSession", dependencies: ["ProxmoxCore"]),
        // Proxmox VE endpoints and models. Portable.
        .target(name: "PVEKit", dependencies: ["ProxmoxCore"]),
        // App domain: saved servers, credentials, live connections.
        .target(name: "FleetCore", dependencies: ["ProxmoxCore", "ProxmoxURLSession", "PVEKit", "DemoServer"]),
        // In-memory fake Proxmox VE cluster used by demo mode, previews and tests.
        .target(name: "DemoServer", dependencies: ["ProxmoxCore"]),

        .testTarget(name: "ProxmoxCoreTests", dependencies: ["ProxmoxCore"]),
        .testTarget(name: "PVEKitTests", dependencies: ["PVEKit", "DemoServer"]),
        .testTarget(name: "FleetCoreTests", dependencies: ["FleetCore", "DemoServer"]),
    ],
    swiftLanguageModes: [.v6]
)
