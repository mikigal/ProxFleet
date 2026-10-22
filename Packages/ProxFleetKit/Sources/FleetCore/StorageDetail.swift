import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// One storage as seen from one node: status, content, uploads, downloads and deletions.
@MainActor
@Observable
public final class StorageDetail {
    public let node: String
    public let storage: String
    public let connection: ServerConnection

    public private(set) var status: StorageStatus?
    public private(set) var volumes: [StorageVolume]?
    /// The backups on the storage, with notes and protection; nil when it holds no backups.
    public private(set) var backups: [BackupVolume]?
    /// Usage over the chosen timeframe.
    public private(set) var history: [RRDPoint] = []
    public private(set) var privileges: Set<String>?
    public private(set) var loadError: String?
    /// The running upload: file name and the fraction sent so far.
    public private(set) var upload: (fileName: String, fraction: Double)?
    /// Why the last upload failed, for screens that let it run on after their form closed.
    public var uploadError: String?

    public var timeframe: RRDTimeframe = .day {
        didSet {
            guard timeframe != oldValue else { return }
            Task { await loadHistory() }
        }
    }

    public init(node: String, storage: String, connection: ServerConnection) {
        self.node = node
        self.storage = storage
        self.connection = connection
    }

    /// Whether the user holds a privilege on `/storage/{storage}`. Unknown privileges count as granted.
    public func can(_ privilege: String) -> Bool {
        privileges?.contains(privilege) ?? true
    }

    /// Volumes of one content type, newest first; ISO images and templates by name.
    public func volumes(of content: StorageContentType) -> [StorageVolume] {
        let matching = (volumes ?? []).filter { $0.content == content.rawValue }
        switch content {
        case .backup, .images, .rootdir:
            return matching.sorted { ($0.vmid ?? 0, $0.created ?? .distantPast) < ($1.vmid ?? 0, $1.created ?? .distantPast) }
        default:
            return matching.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        }
    }

    // MARK: - Loading

    public func load() async {
        async let privileges = try? connection.session.privileges(on: "/storage/\(storage)")
        do {
            let status = try await connection.session.send(PVE.storageStatus(node: node, storage: storage))
            self.status = status
            volumes = try await connection.session.send(PVE.storageVolumes(node: node, storage: storage))
            backups = status.content.contains("backup") ? try await connection.session.send(PVE.backups(node: node, storage: storage)) : nil
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let privileges = await privileges { self.privileges = privileges }
    }

    public func loadHistory() async {
        if let points = try? await connection.session.send(PVE.storageRRD(node: node, storage: storage, timeframe: timeframe)) {
            history = points.filter { $0.storageTotal != nil }
        }
    }

    /// Changes, deletes or prunes backups and waits for the task, then reloads the content.
    public func runBackupAction(_ request: APIRequest<String?>) async throws(ConfigUpdateError) {
        do {
            try await runTask(request)
        } catch {
            await load()
            throw error
        }
        await load()
    }

    /// Lets the node pull an OCI image as a container template. Returns once the task started.
    public func pullOCIImage(_ draft: OCIPullDraft) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        do {
            let upid = try await connection.session.send(PVE.pullOCIImage(node: node, storage: storage, draft))
            return try connection.tasks.track(upid, reportsFailure: true)
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func ociTags(of reference: String) async throws -> [String] {
        try await connection.session.send(PVE.ociTags(node: node, reference: reference))
    }

    // MARK: - Actions

    public func delete(_ volume: StorageVolume) async throws(ConfigUpdateError) {
        try await runTask(PVE.deleteVolume(node: node, storage: storage, volume: volume.volumeID))
        await load()
    }

    /// Asks the node what a URL would download, to fill in the file name.
    public func metadata(of url: String, verifyCertificates: Bool) async throws -> URLMetadata {
        try await connection.session.send(PVE.urlMetadata(node: node, url: url, verifyCertificates: verifyCertificates))
    }

    /// Lets the node download a file. Returns once the download task is started; it shows in the task list.
    public func download(_ draft: StorageFileDraft) async throws(ConfigUpdateError) -> TaskCenter.TrackedTask? {
        do {
            guard let upid = try await connection.session.send(PVE.downloadURL(node: node, storage: storage, draft)) else { return nil }
            return try connection.tasks.track(upid, reportsFailure: true)
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    /// Uploads a file from the device and waits until the node copied it into place.
    public func upload(_ file: URL, as draft: StorageFileDraft) async throws(ConfigUpdateError) {
        let name = draft.fileName.trimmingCharacters(in: .whitespaces)
        upload = (fileName: name, fraction: 0)
        uploadError = nil
        defer { upload = nil }
        do {
            let upid = try await connection.session.upload(
                PVE.uploadFile(node: node, storage: storage, draft), fileField: "filename", fileName: name, source: file
            ) { sent, total in
                Task { @MainActor [weak self] in
                    guard total > 0, self?.upload != nil else { return }
                    self?.upload = (fileName: name, fraction: Double(sent) / Double(total))
                }
            }
            if let upid {
                let task = try connection.tasks.track(upid, reportsFailure: false)
                if case .failed(let message) = await connection.tasks.result(of: task.id) {
                    throw ProxmoxError.api(status: 500, message: message, fieldErrors: [:])
                }
            }
        } catch {
            let failure = ConfigUpdateError(error)
            uploadError = String(localized: "\(name): \(failure.localizedDescription)")
            throw failure
        }
        await load()
    }

    private func runTask(_ request: APIRequest<String?>) async throws(ConfigUpdateError) {
        do {
            guard let upid = try await connection.session.send(request) else { return }
            let task = try connection.tasks.track(upid, reportsFailure: false)
            if case .failed(let message) = await connection.tasks.result(of: task.id) {
                throw ProxmoxError.api(status: 500, message: message, fieldErrors: [:])
            }
        } catch {
            throw ConfigUpdateError(error)
        }
    }
}
