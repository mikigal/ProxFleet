import FleetCore
import PBSKit
import QuickLook
import SwiftUI

/// Browses the files of a backup, like the web interface's file browser: open folders, download files, or whole
/// folders as zip.
struct BackupFilesView: View {
    let files: any BackupFileBrowser
    let filePath: String
    let title: String
    /// Shown while a folder takes long to open, such as a VM disk that needs a restore VM first.
    var slowLoadingHint: String?
    /// False for the list of archives or VM disks, which cannot be downloaded as one zip.
    var canDownloadFolder: Bool
    @State private var entries: [CatalogEntry]?
    @State private var errorMessage: String?
    @State private var isSlow = false
    @State private var downloading: String?
    @State private var downloadedFile: URL?
    @State private var downloadError: String?

    init(files: any BackupFileBrowser, filePath: String? = nil, title: String, slowLoadingHint: String? = nil, canDownloadFolder: Bool? = nil) {
        self.files = files
        self.filePath = filePath ?? files.rootPath
        self.title = title
        self.slowLoadingHint = slowLoadingHint
        // A backup on a Proxmox VE storage starts at `/`, its archives or disks.
        self.canDownloadFolder = canDownloadFolder ?? (self.filePath != "/")
    }

    var body: some View {
        List {
            if let entries {
                ForEach(entries) { entry in
                    if entry.isDirectory {
                        NavigationLink {
                            BackupFilesView(files: files, filePath: entry.filePath, title: entry.name, slowLoadingHint: slowLoadingHint,
                                            canDownloadFolder: entry.kind != .virtual)
                        } label: {
                            CatalogEntryRow(entry: entry, isDownloading: downloading == entry.id)
                        }
                        .swipeActions {
                            if entry.kind != .virtual {
                                Button("Download", systemImage: "arrow.down.circle") { download(entry) }
                                    .tint(.blue)
                            }
                        }
                        .accessibilityIdentifier("catalog.\(entry.name)")
                    } else {
                        Button {
                            download(entry)
                        } label: {
                            CatalogEntryRow(entry: entry, isDownloading: downloading == entry.id)
                        }
                        .foregroundStyle(.primary)
                        .disabled(downloading != nil || entry.kind != .file)
                        .accessibilityIdentifier("catalog.\(entry.name)")
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if let errorMessage {
                ContentUnavailableView("Cannot Open the Folder", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if entries == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    if isSlow, let slowLoadingHint {
                        Text(slowLoadingHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            } else if entries?.isEmpty == true {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        .toolbar {
            if canDownloadFolder {
                ToolbarItem(placement: .primaryAction) {
                    Button("Download Folder", systemImage: "arrow.down.circle") {
                        download(CatalogEntryFolder.entry(path: filePath, name: title))
                    }
                    .disabled(downloading != nil)
                    .accessibilityIdentifier("catalog.downloadFolder")
                }
            }
        }
        .quickLookPreview($downloadedFile)
        .onChange(of: downloadedFile) { old, new in
            // The preview's share button exports the file; afterwards the copy is not needed anymore.
            if new == nil, let old { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
        }
        .alert("Download Failed", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("OK") {}
        } message: {
            Text(downloadError ?? "")
        }
        .task {
            do {
                entries = try await files.entries(at: filePath)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            isSlow = true
        }
    }

    private func download(_ entry: CatalogEntry) {
        downloading = entry.id
        Task {
            defer { downloading = nil }
            do {
                downloadedFile = try await files.download(entry) { _, _ in }
            } catch is CancellationError {
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }
}

/// The current folder as a catalog entry, for Download Folder.
private enum CatalogEntryFolder {
    static func entry(path: String, name: String) -> CatalogEntry {
        let json = #"{"filepath":"\#(path)","text":"\#(name.replacingOccurrences(of: "\"", with: ""))","type":"d","leaf":false}"#
        // Built from known values; decoding cannot fail.
        return try! JSONDecoder().decode(CatalogEntry.self, from: Data(json.utf8))
    }
}

private struct CatalogEntryRow: View {
    let entry: CatalogEntry
    let isDownloading: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(entry.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                if !entry.isDirectory {
                    HStack(spacing: 4) {
                        if let size = entry.size { Text(Format.bytes(size)) }
                        if let modified = entry.modified {
                            Text(verbatim: "·")
                            Text(modified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isDownloading { ProgressView() }
        }
    }

    private var icon: String {
        switch entry.kind {
        case .directory: "folder.fill"
        // An archive at the top, or a VM disk.
        case .virtual: entry.name.hasSuffix(".img.fidx") ? "internaldrive" : "folder.fill"
        case .symlink: "arrow.turn.up.right"
        case .hardlink: "link"
        case .characterDevice, .blockDevice: "cpu"
        case .fifo, .socket: "point.3.connected.trianglepath.dotted"
        case .file, nil: "doc"
        }
    }
}
