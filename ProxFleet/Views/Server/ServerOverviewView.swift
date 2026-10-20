import FleetCore
import PVEKit
import SwiftUI

struct ServerOverviewView: View {
    let connection: ServerConnection

    var body: some View {
        List {
            if let snapshot = connection.snapshot {
                Section {
                    ClusterHeader(snapshot: snapshot)
                }
                Section("Nodes") {
                    ForEach(snapshot.nodes) { node in
                        NodeRow(node: node)
                    }
                }
                guestSection("Virtual Machines", guests: snapshot.virtualMachines.filter { !$0.isTemplate })
                guestSection("Containers", guests: snapshot.containers.filter { !$0.isTemplate })
                guestSection("Templates", guests: snapshot.guests.filter(\.isTemplate))
            }
        }
        .refreshable { await connection.refresh() }
        .task { await connection.keepRefreshing() }
        .safeAreaInset(edge: .bottom) {
            if let error = connection.refreshError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect()
                    .padding(.bottom, 8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                        Task { await connection.signOut() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func guestSection(_ title: LocalizedStringKey, guests: [GuestSummary]) -> some View {
        if !guests.isEmpty {
            Section(title) {
                ForEach(guests) { guest in
                    GuestRow(guest: guest)
                }
            }
        }
    }
}

private struct ClusterHeader: View {
    let snapshot: ClusterSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                switch snapshot.topology {
                case .standalone:
                    Label("Standalone Node", systemImage: "server.rack")
                        .font(.headline)
                case .cluster(let name, let quorate):
                    Label("Cluster \(name)", systemImage: "square.stack.3d.up.fill")
                        .font(.headline)
                    Spacer()
                    Text(quorate ? "Quorate" : "No Quorum")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((quorate ? Color.green : Color.red).opacity(0.15), in: .capsule)
                        .foregroundStyle(quorate ? .green : .red)
                }
            }
            HStack(spacing: 0) {
                Metric(value: "\(snapshot.nodes.filter(\.isOnline).count)/\(snapshot.nodes.count)", label: "Nodes online")
                Metric(value: running(snapshot.virtualMachines), label: "VMs running")
                Metric(value: running(snapshot.containers), label: "CTs running")
            }
        }
        .padding(.vertical, 4)
    }

    private func running(_ guests: [GuestSummary]) -> String {
        let real = guests.filter { !$0.isTemplate }
        return "\(real.filter { $0.state == .running }.count)/\(real.count)"
    }
}

private struct Metric: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NodeRow: View {
    let node: NodeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusDot(color: node.isOnline ? .green : .red)
                Text(node.name)
                    .font(.headline)
                if let ip = node.ip {
                    Text(ip)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if node.isOnline {
                    Text("Up \(Format.uptime(node.uptime))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Offline")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            if node.isOnline {
                HStack(spacing: 16) {
                    UsageGauge(title: "CPU", fraction: node.cpuUsage, detail: "\(node.cpuCount) cores")
                    UsageGauge(title: "Memory", fraction: Format.fraction(node.memoryUsed, of: node.memoryTotal), detail: Format.bytes(node.memoryTotal))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct GuestRow: View {
    let guest: GuestSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: guest.kind == .virtualMachine ? "desktopcomputer" : "shippingbox")
                .font(.title3)
                .foregroundStyle(guest.state == .running ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(guest.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 4) {
                    Text(verbatim: "\(guest.vmid)")
                        .monospacedDigit()
                    Text(verbatim: "·")
                    Text(guest.node)
                    ForEach(guest.tags, id: \.self) { tag in
                        TagChip(tag: tag)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if guest.state == .running {
                Text(guest.cpuUsage, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            PowerStateBadge(state: guest.state)
        }
        .accessibilityElement(children: .combine)
    }
}
