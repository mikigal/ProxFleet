import Foundation
import ProxmoxCore

/// When the server sends notifications about a kind of job of a datastore.
public enum NotificationLevel: String, Sendable, CaseIterable, Identifiable {
    case always, error, never
    public var id: String { rawValue }
}

/// The settings of a datastore, for `POST /config/datastore` and `PUT /config/datastore/{name}`. The location
/// (path, device, S3 bucket) is fixed once the datastore exists.
public struct DatastoreDraft: BackupServerDraft, Sendable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        /// A directory on the server.
        case local
        /// A directory on a device that can be detached, found by its file system's UUID.
        case removable
        /// An S3 bucket, with a local cache directory.
        case s3
        public var id: String { rawValue }
    }

    /// The tuning settings this form edits; others are kept as they are.
    public enum TuningKey: String, CaseIterable, Sendable {
        case chunkOrder = "chunk-order"
        case syncLevel = "sync-level"
        case gcAtimeSafetyCheck = "gc-atime-safety-check"
        case gcAtimeCutoff = "gc-atime-cutoff"
        case gcCacheCapacity = "gc-cache-capacity"
        case verificationReaders = "default-verification-readers"
        case verificationWorkers = "default-verification-workers"
    }

    /// The jobs a datastore notifies about, in the web interface's order.
    public static let notificationJobs = ["gc", "verify", "sync", "prune"]

    public var name = ""
    public var kind: Kind = .local
    /// An absolute path, the path on the device for removable datastores, or the local cache for S3.
    public var path = ""
    /// The UUID of the file system of a removable datastore.
    public var backingDevice = ""
    public var s3Endpoint = ""
    public var bucket = ""
    /// Use a datastore that already exists in the directory instead of creating a new one.
    public var reuseExisting = false
    /// S3: take over a bucket that another server marked as in use.
    public var overwriteInUse = false

    public var comment = ""
    public var gcSchedule = ""
    public var pruneSchedule = ""
    public var retention = RetentionPolicy()
    public var verifyNew = false
    /// Empty for the server's default, the notification system.
    public var notificationMode = ""
    public var notifyUser = ""
    /// Levels by job (`gc`, `verify`, `sync`, `prune`) for sendmail notifications; missing ones use the default.
    public var notify: [String: NotificationLevel] = [:]
    public var maintenance: DatastoreMaintenance?
    public var tuning = PropertyMap(parsing: nil)
    public var gcOnUnmount = false

    /// A new datastore with the web interface's defaults: garbage collection and pruning every day.
    public init() {
        gcSchedule = "daily"
        pruneSchedule = "daily"
    }

    public init(_ config: DatastoreConfig) {
        let values = config.values
        name = config.name
        path = config.path
        if config.isS3 {
            kind = .s3
            s3Endpoint = config.backend?["client"] ?? ""
            bucket = config.backend?["bucket"] ?? ""
        } else if let device = config.backingDevice {
            kind = .removable
            backingDevice = device
        }
        comment = config.comment ?? ""
        gcSchedule = config.gcSchedule ?? ""
        pruneSchedule = config.pruneSchedule ?? ""
        retention = config.retention
        verifyNew = config.verifyNew
        notificationMode = values["notification-mode"] ?? ""
        notifyUser = values["notify-user"] ?? ""
        let notifyValues = PropertyString(parsing: values["notify"] ?? "")
        for job in Self.notificationJobs {
            notify[job] = notifyValues[job].flatMap(NotificationLevel.init)
        }
        maintenance = config.maintenance
        tuning = PropertyMap(parsing: values["tuning"])
        gcOnUnmount = values["gc-on-unmount"] == "1"
    }

    /// Sendmail notifications go to `notify-user` with the levels of `notify`; the notification system uses matchers.
    public var usesSendmail: Bool { notificationMode == "legacy-sendmail" }

    public func serialized() -> [String: String?] {
        func text(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        var values: [String: String?] = [
            "comment": text(comment),
            "gc-schedule": text(gcSchedule),
            "prune-schedule": text(pruneSchedule),
            "verify-new": verifyNew ? "1" : nil,
            "notification-mode": text(notificationMode),
            "notify-user": text(notifyUser),
            "maintenance-mode": maintenance?.stringValue,
            "tuning": tuning.stringValue,
        ]
        let levels = Self.notificationJobs.compactMap { job in notify[job].map { "\(job)=\($0.rawValue)" } }
        // `updateValue`, as assigning nil would drop the key instead of marking the setting as cleared.
        values.updateValue(levels.isEmpty ? nil : levels.joined(separator: ","), forKey: "notify")
        if kind == .removable { values.updateValue(gcOnUnmount ? "1" : nil, forKey: "gc-on-unmount") }
        for (key, value) in retention.serialized { values.updateValue(value, forKey: key) }
        return values
    }

    /// Parameters of `POST /config/datastore`.
    /// - Parameter usesNotificationSystem: new datastores use the notification system, as the web interface creates
    ///   them, on releases that have it.
    public func creationParameters(usesNotificationSystem: Bool) -> APIParameters {
        var parameters: APIParameters = ["name": .string(name.trimmingCharacters(in: .whitespaces))]
        parameters["path"] = .string(path.trimmingCharacters(in: .whitespaces))
        for item in creationValues.items where item.name != "maintenance-mode" {
            parameters[item.name] = item.value
        }
        switch kind {
        case .local:
            break
        case .removable:
            parameters["backing-device"] = .string(backingDevice)
        case .s3:
            parameters["backend"] = .string("type=s3,client=\(s3Endpoint),bucket=\(bucket)")
            if overwriteInUse { parameters["overwrite-in-use"] = true }
        }
        if reuseExisting { parameters["reuse-datastore"] = true }
        if usesNotificationSystem, notificationMode.isEmpty { parameters["notification-mode"] = "notification-system" }
        return parameters
    }

    /// Problems the form can find itself, by parameter name as the server reports them.
    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew {
            let name = name.trimmingCharacters(in: .whitespaces)
            if name.count < 3 || name.count > 32 || name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._\-]*/) == nil {
                problems["name"] = String(localized: "Use 3 to 32 letters, digits, dots, dashes or underscores, not starting with a dot or dash.")
            }
            let path = path.trimmingCharacters(in: .whitespaces)
            switch kind {
            case .local, .s3:
                if !path.hasPrefix("/") { problems["path"] = String(localized: "Enter an absolute path, e.g. /mnt/datastore/store1.") }
            case .removable:
                if path.isEmpty || path.hasPrefix("/") { problems["path"] = String(localized: "Enter a path on the device, e.g. backups.") }
                if backingDevice.isEmpty { problems["backing-device"] = String(localized: "Choose the device.") }
            }
            if kind == .s3 {
                if s3Endpoint.isEmpty { problems["backend"] = String(localized: "Choose an S3 endpoint.") }
                if bucket.trimmingCharacters(in: .whitespaces).isEmpty { problems["bucket"] = String(localized: "Enter the bucket.") }
            }
        }
        if let message = maintenance?.message, message.count > 64 {
            problems["maintenance-mode"] = String(localized: "The message can be 64 characters long at most.")
        }
        return problems
    }
}

extension PBS {
    /// Creates a datastore; returns the task, which creates the chunk store.
    public static func createDatastore(_ parameters: APIParameters) -> APIRequest<String> {
        APIRequest(.post, "/config/datastore", parameters: parameters)
    }

    public static func updateDatastore(_ name: String, _ update: BackupServerConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/config/datastore/\(escapePath(name))", parameters: update.parameters)
    }
}
