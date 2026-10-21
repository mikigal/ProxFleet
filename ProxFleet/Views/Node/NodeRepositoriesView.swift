import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The node's APT repositories: status like the web interface's, enable and disable, add standard ones.
struct NodeRepositoriesView: View {
    let detail: NodeDetail
    @State private var addsRepository = false
    @State private var working: String?
    @State private var errorMessage: String?

    private var canModify: Bool { detail.can("Sys.Modify") }

    var body: some View {
        List {
            if let repositories = detail.repositories {
                statusSection(repositories)
                ForEach(repositories.files) { file in
                    Section {
                        ForEach(file.repositories) { repository in
                            row(repository)
                        }
                    } header: {
                        Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                    }
                }
            }
        }
        .overlay {
            if let errorMessage, detail.repositories == nil {
                ContentUnavailableView("Cannot Load the Repositories", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if detail.repositories == nil {
                ProgressView()
            }
        }
        .navigationTitle("Repositories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { addsRepository = true }
                    .disabled(!canModify || detail.repositories == nil)
                    .accessibilityIdentifier("repositories.add")
            }
        }
        .refreshable { errorMessage = await detail.loadRepositories() }
        .task { errorMessage = await detail.loadRepositories() }
        .sheet(isPresented: $addsRepository) {
            NavigationStack {
                AddRepositoryView(detail: detail)
            }
        }
        .alert("Repository Error", isPresented: Binding(get: { errorMessage != nil && detail.repositories != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func statusSection(_ repositories: AptRepositories) -> some View {
        Section {
            if !repositories.hasEnabledProxmoxRepository {
                Label("No Proxmox VE repository is enabled, so the node gets no Proxmox VE updates.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if repositories.hasEnabledEnterpriseRepository, detail.subscription?.isActive == false {
                Label("The enterprise repository is enabled, but the node has no active subscription. Refreshing the package list fails for it.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Proxmox VE updates are available.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if repositories.repositories.contains(where: { $0.isEnabled && $0.components.contains { $0.hasSuffix("no-subscription") } }) {
                Label("The No-Subscription repository is not recommended for production use.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if repositories.repositories.contains(where: { $0.isEnabled && $0.components.contains { $0.hasSuffix("-test") } }) {
                Label("The Test repository has packages that are not ready for production use.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(repositories.errors, id: \.path) { error in
                Label("\(error.path): \(error.message)", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            if let subscription = detail.subscription {
                LabeledContent("Subscription", value: subscription.isActive ? (subscription.productName ?? String(localized: "Active")) : String(localized: "None"))
            }
        } header: {
            Text("Status")
        }
        .font(.subheadline)
    }

    private func row(_ repository: AptRepositories.Repository) -> some View {
        Toggle(isOn: Binding(get: { repository.isEnabled }, set: { enabled in Task { await set(repository, enabled: enabled) } })) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(repository.components.joined(separator: " "))
                        .font(.body.weight(.medium))
                    if let origin = repository.origin {
                        Text(origin)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                    if working == repository.id { ProgressView().controlSize(.small) }
                }
                Text("\(repository.uris.joined(separator: " ")) \(repository.suites.joined(separator: " "))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let comment = repository.comment {
                    Text(comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(repository.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .disabled(!canModify || working != nil)
        .accessibilityIdentifier("repository.\(repository.components.joined(separator: "-"))")
    }

    private func set(_ repository: AptRepositories.Repository, enabled: Bool) async {
        working = repository.id
        defer { working = nil }
        do {
            try await detail.setRepository(repository, enabled: enabled)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The standard repositories with their descriptions, to add or enable one.
private struct AddRepositoryView: View {
    let detail: NodeDetail
    @State private var working: String?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(detail.repositories?.standardRepositories ?? []) { repository in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(repository.name)
                            .font(.headline)
                        Text(repository.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    if repository.isEnabled == true {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            Task { await add(repository) }
                        } label: {
                            HStack {
                                Text(repository.isEnabled == false ? "Enable" : "Add")
                                Spacer()
                                if working == repository.handle { ProgressView() }
                            }
                        }
                        .disabled(working != nil)
                        .accessibilityIdentifier("standard.\(repository.handle)")
                    }
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Add Repository")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func add(_ repository: AptRepositories.StandardRepository) async {
        working = repository.handle
        errorMessage = nil
        defer { working = nil }
        do {
            try await detail.addStandardRepository(repository.handle)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
