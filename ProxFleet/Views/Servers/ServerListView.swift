import FleetCore
import SwiftUI

struct ServerListView: View {
    @Environment(Fleet.self) private var fleet
    @Binding var selection: UUID?
    @State private var onboarding: ServerOnboarding?
    @State private var pendingDeletion: ServerProfile?
    @State private var renaming: ServerProfile?
    @State private var newName = ""
    @State private var showsSettings = false

    var body: some View {
        List(selection: $selection) {
            ForEach(fleet.profiles) { profile in
                ServerRow(profile: profile, connection: fleet.connection(for: profile.id))
                    .tag(profile.id)
                    .swipeActions {
                        Button("Delete", systemImage: "trash") {
                            pendingDeletion = profile
                        }
                        .tint(.red)
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") {
                            newName = profile.name
                            renaming = profile
                        }
                        Button("Delete", systemImage: "trash") {
                            pendingDeletion = profile
                        }
                        .tint(.red)
                    }
            }
            .onMove { fleet.move(fromOffsets: $0, toOffset: $1) }
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") {
                    showsSettings = true
                }
                .accessibilityIdentifier("settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add Server", systemImage: "plus") {
                    onboarding = fleet.makeOnboarding()
                }
                .accessibilityIdentifier("addServer")
            }
        }
        .overlay {
            if fleet.profiles.isEmpty {
                WelcomeView(onAddServer: { onboarding = fleet.makeOnboarding() })
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
        .sheet(item: $onboarding) { onboarding in
            AddServerFlow(onboarding: onboarding) { profile in
                selection = profile.id
            }
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "")?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { profile in
            Button("Delete Server", role: .destructive) {
                fleet.remove(profile.id)
            }
        } message: { _ in
            Text("The saved password and certificate approval for this server are removed from this device. Nothing changes on the server.")
        }
        .alert("Rename Server", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { profile in
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { fleet.rename(profile.id, to: newName) }
        }
    }
}

extension ServerOnboarding: @retroactive Identifiable {}

private struct ServerRow: View {
    let profile: ServerProfile
    let connection: ServerConnection?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.clusterName == nil ? "server.rack" : "square.stack.3d.up.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.headline)
                    if profile.isDemo {
                        Text("DEMO")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                }
                Text(profile.isDemo ? "Sample data, no server needed" : "\(profile.userID) · \(profile.addressSummary)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let connection {
                ConnectionIndicator(state: connection.state)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("server.\(profile.name)")
    }
}

private struct ConnectionIndicator: View {
    let state: ServerConnection.State

    var body: some View {
        switch state {
        case .connected:
            StatusDot(color: .green)
                .accessibilityLabel("Connected")
        case .connecting:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Connection failed")
        case .needsPassword, .needsSecondFactor, .untrustedCertificate:
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Sign-in required")
        case .disconnected:
            EmptyView()
        }
    }
}

private struct WelcomeView: View {
    let onAddServer: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to ProxFleet", systemImage: "square.stack.3d.up.fill")
        } description: {
            Text("Manage your Proxmox VE servers and clusters. Sign in with the same user name and password you use in the web interface.")
        } actions: {
            Button("Add Server", action: onAddServer)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("welcome.addServer")
        }
    }
}
