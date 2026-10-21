import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI
import UniformTypeIdentifiers

/// Storages as listed in the overview and on node screens. Shared storages show once, through the first
/// node that has them available.
///
/// The links push their screen directly rather than a `ServerRoute`: node screens open this list with a
/// destination link, and a value link inside it was placed under that list in the navigation stack.
struct StorageSection: View {
    let connection: ServerConnection
    let snapshot: ClusterSnapshot
    /// Only the storages of this node; nil for all.
    var node: String?

    private var storages: [StorageSummary] {
        let candidates = snapshot.storages.filter { node == nil || $0.node == node }
        var seenShared = Set<String>()
        return candidates
            .sorted { ($0.isAvailable ? 0 : 1, $0.node) < ($1.isAvailable ? 0 : 1, $1.node) }
            .filter { storage in
                guard storage.isShared, node == nil else { return true }
                return seenShared.insert(storage.name).inserted
            }
            .sorted { $0.name == $1.name ? $0.node < $1.node : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        if !storages.isEmpty {
            Section("Storage") {
                ForEach(storages) { storage in
                    NavigationLink {
                        StorageDetailView(node: storage.node, storage: storage.name, connection: connection)
                    } label: {
                        StorageSummaryRow(storage: storage, showsNode: node == nil && snapshot.nodes.count > 1)
                    }
                    .accessibilityIdentifier("storage.\(storage.node).\(storage.name)")
                }
            }
        }
    }
}

private struct StorageSummaryRow: View {
    let storage: StorageSummary
    let showsNode: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: storage.isShared ? "externaldrive.connected.to.line.below" : "internaldrive")
                .font(.title3)
                .foregroundStyle(storage.isAvailable ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(storage.name)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if storage.isAvailable, storage.total > 0 {
                        Text("\(Format.bytes(storage.used)) of \(Format.bytes(storage.total))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !storage.isAvailable {
                        Text("Unavailable")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if storage.isAvailable, storage.total > 0 {
                    let fraction = Format.fraction(storage.used, of: storage.total)
                    ProgressView(value: fraction)
                        .tint(fraction > 0.9 ? .red : .accentColor)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = [StorageSummaryRow.typeTitle(storage.pluginType ?? "")]
        if storage.isShared { parts.append(String(localized: "shared")) } else if showsNode { parts.append(storage.node) }
        return parts.joined(separator: " · ")
    }

    static func typeTitle(_ type: String) -> String {
        switch type {
        case "dir": String(localized: "Directory")
        case "lvm": "LVM"
        case "lvmthin": "LVM-Thin"
        case "zfspool": "ZFS"
        case "nfs": "NFS"
        case "cifs": "SMB/CIFS"
        case "pbs": String(localized: "Proxmox Backup Server")
        case "rbd": "Ceph RBD"
        case "cephfs": "CephFS"
        case "iscsi", "iscsidirect": "iSCSI"
        case "esxi": "ESXi"
        case "btrfs": "Btrfs"
        default: type
        }
    }
}

extension StorageContentType {
    var title: LocalizedStringKey {
        switch self {
        case .images: "VM Disks"
        case .rootdir: "CT Volumes"
        case .iso: "ISO Images"
        case .vztmpl: "CT Templates"
        case .backup: "Backups"
        case .snippets: "Snippets"
        case .import: "Import"
        }
    }

    var systemImage: String {
        switch self {
        case .images: "desktopcomputer"
        case .rootdir: "shippingbox"
        case .iso: "opticaldisc"
        case .vztmpl: "doc.zipper"
        case .backup: "clock.arrow.circlepath"
        case .snippets: "doc.text"
        case .import: "square.and.arrow.down.on.square"
        }
    }
}

// MARK: - Storage

/// A storage's usage and its content, one content type at a time, with downloads and deletion.
struct StorageDetailView: View {
    /// Uploading files from the device is hidden for now (decided 2026-10-21). The code below and the upload
    /// support in the package stay, verified against a real server, so it can be turned back on here.
    static let allowsUploads = false

    @State private var detail: StorageDetail
    @State private var content: StorageContentType?
    @State private var fileTarget: StorageContentType?
    @State private var downloadTarget: StorageContentType?
    @State private var downloadsTemplates = false
    @State private var deleting: StorageVolume?
    @State private var errorMessage: String?

    init(node: String, storage: String, connection: ServerConnection) {
        _detail = State(initialValue: StorageDetail(node: node, storage: storage, connection: connection))
    }

    private var types: [StorageContentType] { detail.status?.contentTypes ?? [] }
    private var selected: StorageContentType? { content ?? types.first }
    private var canAllocate: Bool { detail.can("Datastore.AllocateSpace") || detail.can("Datastore.AllocateTemplate") }

    var body: some View {
        List {
            if let status = detail.status {
                Section {
                    LabeledContent("Type", value: StorageSummaryRow.typeTitle(status.type))
                    if status.total > 0 {
                        UsageGauge(title: "Usage", fraction: Format.fraction(status.used, of: status.total),
                                   detail: "\(Format.bytes(status.used)) of \(Format.bytes(status.total)), \(Format.bytes(status.available)) free")
                    }
                    LabeledContent("Shared", value: status.isShared ? String(localized: "Yes") : String(localized: "No"))
                    if !status.isActive {
                        Label("The storage is not active on \(detail.node).", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if let upload = detail.upload {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Uploading \(upload.fileName)")
                            .font(.subheadline.weight(.medium))
                        ProgressView(value: upload.fraction)
                        Text(upload.fraction >= 1 ? "Copying into place…" : "\(Int(upload.fraction * 100))% sent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Keep the app open until the upload finishes.")
                }
            }
            if types.count > 1 {
                Section {
                    Picker("Content", selection: Binding(get: { selected ?? .iso }, set: { content = $0 })) {
                        ForEach(types) { type in
                            Label(type.title, systemImage: type.systemImage).tag(type)
                        }
                    }
                    .accessibilityIdentifier("storage.content")
                }
            }
            if let selected, detail.volumes != nil {
                let volumes = detail.volumes(of: selected)
                Section {
                    if volumes.isEmpty {
                        Text("No \(Text(selected.title))")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(volumes) { volume in
                        VolumeRow(volume: volume, content: selected, guestName: guestName(volume.vmid))
                            .swipeActions {
                                // Not `role: .destructive`: that hides the row on a full swipe, but this only asks first.
                                if canAllocate, !volume.isProtected {
                                    Button("Delete", systemImage: "trash") { deleting = volume }
                                        .tint(.red)
                                }
                            }
                            .contextMenu {
                                Button("Copy Volume ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = volume.volumeID }
                                if canAllocate, !volume.isProtected {
                                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = volume }
                                }
                            }
                    }
                } header: {
                    Text(selected.title)
                } footer: {
                    if selected == .images || selected == .rootdir {
                        Text("Disks still used by a guest cannot be deleted here; remove them from the guest's hardware first.")
                    }
                }
            }
        }
        .overlay {
            if let error = detail.loadError, detail.status == nil {
                ContentUnavailableView("Cannot Load the Storage", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if detail.status == nil {
                ProgressView()
            }
        }
        .navigationTitle(detail.storage)
        .navigationSubtitle(detail.node)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    ForEach(types.filter(\.acceptsFiles)) { type in
                        Section(type.title) {
                            if Self.allowsUploads {
                                Button("Upload from Files", systemImage: "folder") { fileTarget = type }
                                    .accessibilityIdentifier("storage.upload.\(type.rawValue)")
                            }
                            Button("Download from URL", systemImage: "link") { downloadTarget = type }
                                .accessibilityIdentifier("storage.download.\(type.rawValue)")
                            if type == .vztmpl {
                                Button("Download Templates", systemImage: "square.and.arrow.down") { downloadsTemplates = true }
                            }
                        }
                    }
                }
                .disabled(!types.contains(where: \.acceptsFiles) || detail.upload != nil || !canAllocate)
                .accessibilityIdentifier("storage.add")
            }
        }
        .refreshable { await detail.load() }
        .task { await detail.load() }
        .sheet(item: $fileTarget) { type in
            NavigationStack {
                UploadFileView(detail: detail, content: type)
            }
        }
        .sheet(item: $downloadTarget) { type in
            NavigationStack {
                DownloadURLView(detail: detail, content: type)
            }
        }
        .sheet(isPresented: $downloadsTemplates, onDismiss: { Task { await detail.load() } }) {
            NavigationStack {
                TemplateDownloadView(connection: detail.connection, node: detail.node) { _ in }
            }
        }
        .confirmationDialog("Delete \(deleting?.fileName ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { volume in
            Button("Delete", role: .destructive) { Task { await delete(volume) } }
                .accessibilityIdentifier("volume.delete.confirm")
        } message: { volume in
            Text("\(volume.volumeID) is deleted from the storage. This cannot be undone.")
        }
        .alert("Storage Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Upload Failed", isPresented: Binding(get: { detail.uploadError != nil }, set: { if !$0 { detail.uploadError = nil } })) {
            Button("OK") {}
        } message: {
            Text(detail.uploadError ?? "")
        }
    }

    private func guestName(_ vmid: Int?) -> String? {
        guard let vmid else { return nil }
        return detail.connection.snapshot?.guests.first { $0.vmid == vmid }?.name
    }

    private func delete(_ volume: StorageVolume) async {
        do {
            try await detail.delete(volume)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct VolumeRow: View {
    let volume: StorageVolume
    let content: StorageContentType
    let guestName: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: content.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(2)
                    if volume.isProtected {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Protected")
                    }
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let notes = volume.notes {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("volume.\(volume.fileName)")
    }

    private var title: String {
        switch content {
        case .images, .rootdir, .backup:
            if let vmid = volume.vmid {
                return [String(vmid), guestName].compactMap { $0 }.joined(separator: " · ") + (content == .backup ? "" : " – \(volume.fileName)")
            }
            return volume.fileName
        default:
            return volume.fileName
        }
    }

    private var details: String {
        var parts: [String] = []
        if let size = volume.size { parts.append(Format.bytes(size)) }
        if let format = volume.format { parts.append(format) }
        if let created = volume.created { parts.append(created.formatted(date: .abbreviated, time: content == .backup ? .shortened : .omitted)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Upload and download

/// Picks a file from Files and uploads it with an optional checksum.
private struct UploadFileView: View {
    let detail: StorageDetail
    @State private var draft: StorageFileDraft
    @State private var file: URL?
    @State private var fileSize: Int64?
    @State private var picksFile = false
    @State private var isUploading = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(detail: StorageDetail, content: StorageContentType) {
        self.detail = detail
        _draft = State(initialValue: StorageFileDraft(content: content))
    }

    private var problems: [String: String] { showsProblems ? draft.problems(forUpload: true) : [:] }

    var body: some View {
        Form {
            Section {
                Button {
                    picksFile = true
                } label: {
                    LabeledContent("File") {
                        Text(file?.lastPathComponent ?? String(localized: "Choose…"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityIdentifier("upload.file")
                if let fileSize {
                    LabeledContent("Size", value: Format.bytes(fileSize))
                }
                LabeledTextField(title: "File Name", prompt: "image.iso", text: $draft.fileName, identifier: "upload.name")
                FieldError(message: problems["filename"])
            } footer: {
                Text("Saved on \(detail.storage) as \(Text(draft.content.title)). Accepted endings: \(draft.content.fileExtensions.joined(separator: ", ")).")
            }
            ChecksumSection(draft: $draft, error: problems["checksum"])
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Upload")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Upload") { start() }
                    .fontWeight(.semibold)
                    .disabled(file == nil || isUploading)
                    .accessibilityIdentifier("upload.start")
            }
        }
        .fileImporter(isPresented: $picksFile, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            file = url
            let access = url.startAccessingSecurityScopedResource()
            fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
            if access { url.stopAccessingSecurityScopedResource() }
            if draft.fileName.isEmpty || draft.fileName == file?.lastPathComponent { draft.fileName = url.lastPathComponent }
        }
    }

    /// The upload continues after the sheet closes; the storage screen shows its progress.
    private func start() {
        showsProblems = true
        guard let file, draft.problems(forUpload: true).isEmpty else { return }
        isUploading = true
        let detail = detail
        let draft = draft
        Task {
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            let background = await UIApplication.shared.beginBackgroundTask(withName: "Upload")
            defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(background) } }
            // A failure shows on the storage screen through `uploadError`.
            try? await detail.upload(file, as: draft)
        }
        dismiss()
    }
}

/// Lets the node download a file from a URL, after looking up its name and size.
struct DownloadURLView: View {
    let detail: StorageDetail
    /// Called with the volume ID the file gets once its download task finished successfully.
    var onDownloaded: ((String) -> Void)?
    @State private var draft: StorageFileDraft
    @State private var metadata: URLMetadata?
    @State private var isQuerying = false
    @State private var isStarting = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(detail: StorageDetail, content: StorageContentType, onDownloaded: ((String) -> Void)? = nil) {
        self.detail = detail
        self.onDownloaded = onDownloaded
        _draft = State(initialValue: StorageFileDraft(content: content))
    }

    private var errors: [String: String] { (showsProblems ? draft.problems() : [:]).merging(fieldErrors) { _, server in server } }

    var body: some View {
        Form {
            Section {
                TextField("URL", text: $draft.url, prompt: Text("https://example.com/image.iso"), axis: .vertical)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("download.url")
                FieldError(message: errors["url"])
                Button {
                    Task { await query() }
                } label: {
                    HStack {
                        Text("Query URL")
                        Spacer()
                        if isQuerying { ProgressView() }
                    }
                }
                .disabled(draft.url.isEmpty || isQuerying)
                .accessibilityIdentifier("download.query")
                if let size = metadata?.size {
                    LabeledContent("Size", value: Format.bytes(size))
                }
                LabeledTextField(title: "File Name", prompt: "image.iso", text: $draft.fileName, identifier: "download.name")
                FieldError(message: errors["filename"])
                Toggle("Verify Certificates", isOn: $draft.verifyCertificates)
            } footer: {
                Text("The node downloads the file itself, so the URL must be reachable from \(detail.node). The download continues as a task.")
            }
            ChecksumSection(draft: $draft, error: errors["checksum"])
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Download from URL")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isStarting)
        .onChange(of: draft.url) { _, url in
            if draft.fileName.isEmpty || draft.fileName == metadata?.fileName {
                draft.fileName = StorageFileDraft.fileName(from: url)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Download", isWorking: isStarting) { Task { await start() } }
                    .accessibilityIdentifier("download.start")
            }
        }
    }

    private func query() async {
        isQuerying = true
        errorMessage = nil
        defer { isQuerying = false }
        do {
            let metadata = try await detail.metadata(of: draft.url.trimmingCharacters(in: .whitespaces), verifyCertificates: draft.verifyCertificates)
            self.metadata = metadata
            if let name = metadata.fileName { draft.fileName = name }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func start() async {
        showsProblems = true
        fieldErrors = [:]
        guard draft.problems().isEmpty else { return }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        do {
            if let task = try await detail.download(draft) {
                let detail = detail
                let onDownloaded = onDownloaded
                let folder = draft.content == .iso ? "iso" : draft.content == .vztmpl ? "vztmpl" : "import"
                let volume = "\(detail.storage):\(folder)/\(draft.fileName.trimmingCharacters(in: .whitespaces))"
                Task {
                    let result = await detail.connection.tasks.result(of: task.id)
                    await detail.load()
                    if result == .succeeded { onDownloaded?(volume) }
                }
            }
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Downloads an ISO image from a URL for the VM wizard: picks a storage with ISO content first when there are several.
struct ISODownloadView: View {
    let connection: ServerConnection
    let node: String
    let onDownloaded: (String) -> Void
    @State private var storages: [StorageInfo]?

    var body: some View {
        Group {
            if let storages, storages.count == 1 {
                DownloadURLView(detail: StorageDetail(node: node, storage: storages[0].storage, connection: connection), content: .iso, onDownloaded: onDownloaded)
            } else if let storages {
                List {
                    Section {
                        ForEach(storages) { storage in
                            NavigationLink(storage.storage) {
                                DownloadURLView(detail: StorageDetail(node: node, storage: storage.storage, connection: connection), content: .iso, onDownloaded: onDownloaded)
                            }
                        }
                    } footer: {
                        Text(storages.isEmpty ? "No storage on \(node) holds ISO images." : "Choose where to save the image.")
                    }
                }
                .navigationTitle("Download ISO")
            } else {
                ProgressView()
            }
        }
        .task { storages = await connection.load(PVE.storages(node: node, content: "iso")).filter(\.isActive) }
    }
}

private struct ChecksumSection: View {
    @Binding var draft: StorageFileDraft
    let error: String?

    var body: some View {
        Section {
            Picker("Algorithm", selection: $draft.checksumAlgorithm) {
                ForEach(StorageFileDraft.checksumAlgorithms, id: \.self) { Text($0.uppercased()).tag($0) }
            }
            TextField("Checksum", text: $draft.checksum, prompt: Text("Optional"), axis: .vertical)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            FieldError(message: error)
        } header: {
            Text("Checksum")
        } footer: {
            Text("With a checksum, Proxmox verifies the file and discards it when it does not match.")
        }
    }
}

