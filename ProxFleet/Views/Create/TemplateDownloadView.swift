import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Container templates the node can download from the Proxmox and TurnKey Linux repositories.
struct TemplateDownloadView: View {
    let connection: ServerConnection
    let node: String
    /// Called with the volume ID of a downloaded template the user picked.
    let onSelect: (String) -> Void
    @State private var templates: [ApplianceTemplate] = []
    @State private var downloaded: [StorageVolume] = []
    @State private var storages: [StorageInfo] = []
    @State private var isLoading = true
    @State private var search = ""
    @State private var pending: ApplianceTemplate?
    /// Running downloads: template file name → task ID.
    @State private var downloads: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var isVisible = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.templates) { template in
                        row(template)
                    }
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if templates.isEmpty {
                ContentUnavailableView("No Templates", systemImage: "shippingbox", description: Text("The node could not load the template list. Run “pveam update” on the node and try again."))
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search)
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Download \(pending?.template ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending) { template in
            ForEach(storages) { storage in
                Button("Download to \(storage.storage)") { Task { await download(template, to: storage.storage) } }
            }
        }
        .alert("Download Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await load() }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            for id in downloads.values { connection.tasks.reportFailure(of: id) }
        }
    }

    private var sections: [(title: String, templates: [ApplianceTemplate])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = templates.filter { template in
            query.isEmpty || template.headline.localizedCaseInsensitiveContains(query) || template.template.localizedCaseInsensitiveContains(query)
        }
        let order = ["system", "turnkeylinux"]
        let names = Set(matching.map(\.section)).sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        return names.map { name in
            let title = switch name {
            case "system": String(localized: "Distributions")
            case "turnkeylinux": String(localized: "TurnKey Linux Appliances")
            default: name.capitalized
            }
            let templates = matching.filter { $0.section == name }.sorted { $0.headline.localizedStandardCompare($1.headline) == .orderedAscending }
            return (title, templates)
        }
    }

    private func row(_ template: ApplianceTemplate) -> some View {
        let volume = downloaded.first { $0.fileName == template.template }
        return Button {
            if let volume {
                onSelect(volume.volumeID)
                dismiss()
            } else if downloads[template.template] == nil {
                pending = template
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.headline)
                        .foregroundStyle(.primary)
                    Text(template.summary ?? template.template)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if downloads[template.template] != nil {
                    ProgressView()
                } else if volume != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Downloaded")
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Download")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("template.\(template.template)")
    }

    private func load() async {
        async let templates = connection.load(PVE.applianceTemplates(node: node))
        async let downloaded = connection.volumes(node: node, content: "vztmpl")
        async let storages = connection.load(PVE.storages(node: node, content: "vztmpl"))
        self.templates = await templates
        self.downloaded = await downloaded
        self.storages = await storages.filter(\.isActive)
        isLoading = false
    }

    private func download(_ template: ApplianceTemplate, to storage: String) async {
        do {
            let task = try await connection.start(PVE.downloadTemplate(node: node, storage: storage, template: template.template))
            downloads[template.template] = task.id
            let result = await connection.tasks.result(of: task.id)
            downloads[template.template] = nil
            if case .failed(let message) = result {
                errorMessage = message
                return
            }
            onSelect("\(storage):vztmpl/\(template.template)")
            // A download may finish after the user went back.
            if isVisible { dismiss() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
