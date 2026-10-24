import FleetCore
import PBSKit
import ProxmoxCore
import SwiftUI

private var settingsLock: String { missingPrivilegeMessage("Sys.Modify", on: "/system") }

/// Text items, such as networks or time frames, edited as rows.
struct StringListSection: View {
    let title: LocalizedStringKey
    @Binding var items: [String]
    let prompt: LocalizedStringKey
    let identifier: String
    var footer: LocalizedStringKey?
    var error: String?
    @State private var newItem = ""

    var body: some View {
        Section {
            ForEach(items.indices, id: \.self) { index in
                TextField(prompt, text: $items[index])
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .onDelete { items.remove(atOffsets: $0) }
            HStack {
                TextField(prompt, text: $newItem)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                    .accessibilityIdentifier("\(identifier).new")
                Button("Add", systemImage: "plus.circle.fill", action: add)
                    .labelStyle(.iconOnly)
                    .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("\(identifier).add")
            }
            FieldError(message: error)
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }

    private func add() {
        let item = newItem.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else { return }
        if !items.contains(item) { items.append(item) }
        newItem = ""
    }
}

// MARK: - Traffic control

/// Rate limits for clients by network, user and time, with the traffic each rule lets through right now.
struct TrafficControlView: View {
    let settings: BackupServerSettings
    @State private var creating = false
    @State private var deleting: TrafficControlRule?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let rules = settings.trafficRules {
                Section {
                    ForEach(rules) { rule in
                        NavigationLink {
                            TrafficControlEditor(settings: settings, rule: rule)
                        } label: {
                            TrafficRuleRow(rule: rule, current: settings.currentTraffic[rule.name])
                        }
                        .accessibilityIdentifier("traffic.\(rule.name)")
                        .swipeActions {
                            if settings.canModify {
                                Button("Delete", systemImage: "trash") { deleting = rule }
                                    .tint(.red)
                            }
                        }
                    }
                } footer: {
                    if !rules.isEmpty {
                        Text("Limits apply to backup, restore and sync traffic of matching clients. The current rate refreshes every few seconds.")
                    }
                }
            }
        }
        .navigationTitle("Traffic Control")
        .overlay {
            if settings.trafficRules == nil {
                if let error = settings.loadError {
                    ContentUnavailableView("Cannot Load the Rules", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            } else if settings.trafficRules?.isEmpty == true {
                ContentUnavailableView("No Rules", systemImage: "gauge.with.dots.needle.bottom.50percent",
                                       description: Text("Limit the bandwidth clients use, by network, user or time of day."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!settings.canModify)
                    .accessibilityIdentifier("traffic.add")
            }
        }
        .refreshable { await settings.loadTrafficControl() }
        .task {
            await settings.loadTrafficControl()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await settings.loadCurrentTraffic()
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                TrafficControlEditor(settings: settings, rule: nil)
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { rule in
            Button("Delete Rule", role: .destructive) {
                Task {
                    do {
                        try await settings.deleteTrafficRule(rule.name)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        .alert("Cannot Delete the Rule", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct TrafficRuleRow: View {
    let rule: TrafficControlRule
    let current: TrafficControlRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.name).font(.body.weight(.medium))
            Text([rule.rateIn.map { String(localized: "In \($0)/s") }, rule.rateOut.map { String(localized: "Out \($0)/s") }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text((rule.users.isEmpty ? rule.networks : rule.users).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let current, (current.currentRateIn ?? 0) > 0 || (current.currentRateOut ?? 0) > 0 {
                Text("Now: in \(Int64(current.currentRateIn ?? 0).formatted(.byteCount(style: .binary, spellsOutZero: false)))/s, out \(Int64(current.currentRateOut ?? 0).formatted(.byteCount(style: .binary, spellsOutZero: false)))/s")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TrafficControlEditor: View {
    let settings: BackupServerSettings
    let rule: TrafficControlRule?
    private let original: TrafficControlDraft
    @State private var draft: TrafficControlDraft

    init(settings: BackupServerSettings, rule: TrafficControlRule?) {
        self.settings = settings
        self.rule = rule
        var draft = rule.map(TrafficControlDraft.init) ?? TrafficControlDraft()
        if rule == nil { draft.networks = ["0.0.0.0/0", "::/0"] }
        original = draft
        _draft = State(initialValue: draft)
    }

    var body: some View {
        BackupServerJobForm(title: rule?.name ?? String(localized: "New Rule"), isNew: rule == nil, lockMessage: settings.canModify ? nil : settingsLock,
                            hasChanges: !draft.changes(from: original).isEmpty, problems: problems,
                            submit: save, delete: deleteAction,
                            deleteTitle: "Delete Rule", deleteMessage: "Clients it limited are no longer limited.", content: formContent)
    }

    private func problems() -> [String: String] { draft.problems(isNew: rule == nil) }

    private var deleteAction: (() async throws(ConfigUpdateError) -> Void)? {
        guard rule != nil else { return nil }
        return { () async throws(ConfigUpdateError) in try await remove() }
    }

    @ViewBuilder
    private func formContent(_ errors: [String: String]) -> some View {
        Section {
            if rule == nil {
                LabeledTextField(title: "Name", prompt: "office-hours", text: $draft.name, identifier: "traffic.name")
                FieldError(message: errors["name"])
            }
            LabeledTextField(title: "Comment", prompt: "None", text: $draft.comment)
        }
        Section {
            ByteRateField(title: "Rate In", rate: $draft.rateIn)
            FieldError(message: errors["rate-in"])
            ByteRateField(title: "Rate Out", rate: $draft.rateOut)
            ByteRateField(title: "Burst In", rate: $draft.burstIn)
            ByteRateField(title: "Burst Out", rate: $draft.burstOut)
        } header: {
            Text("Limits")
        } footer: {
            Text("In is what clients upload (backups), out what they download (restores, syncs from here). A burst lets short peaks through.")
        }
        StringListSection(title: "Networks", items: $draft.networks, prompt: "10.0.0.0/8", identifier: "traffic.network",
                          footer: "Clients from these networks are limited.", error: errors["network"])
        if settings.connection.supports(backupServer: .userTrafficControl) {
            StringListSection(title: "Users", items: $draft.users, prompt: "backup@pbs", identifier: "traffic.user",
                              footer: "Requests of these users are limited, from any network.")
        }
        StringListSection(title: "Time Frames", items: $draft.timeframes, prompt: "mon..fri 8:00-18:00", identifier: "traffic.timeframe",
                          footer: "Without time frames the rule always applies.", error: errors["timeframe"])
    }

    private func save() async throws(ConfigUpdateError) {
        if let rule {
            try await settings.updateTrafficRule(rule.name, draft.changes(from: original))
        } else {
            try await settings.createTrafficRule(draft)
        }
    }

    private func remove() async throws(ConfigUpdateError) {
        if let rule { try await settings.deleteTrafficRule(rule.name) }
    }
}

// MARK: - Metric servers

extension BackupServerMetricServer.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .influxDBHTTP: "InfluxDB (HTTP)"
        case .influxDBUDP: "InfluxDB (UDP)"
        }
    }
}

/// InfluxDB servers the backup server sends its and its datastores' metrics to.
struct BackupServerMetricServersView: View {
    let settings: BackupServerSettings
    @State private var creating: BackupServerMetricServer.Kind?

    var body: some View {
        List {
            ForEach(settings.metricServers ?? []) { server in
                NavigationLink {
                    MetricServerLoader(settings: settings, server: server)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(server.isEnabled ? .primary : .secondary)
                        if let kind = server.kind {
                            Text(kind.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(server.server)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .disabled(server.kind == nil)
                .accessibilityIdentifier("metrics.\(server.name)")
            }
        }
        .navigationTitle("Metric Servers")
        .overlay {
            if settings.metricServers == nil {
                ProgressView()
            } else if settings.metricServers?.isEmpty == true {
                ContentUnavailableView("No Metric Servers", systemImage: "chart.xyaxis.line",
                                       description: Text("Send the server's and datastores' usage to InfluxDB, e.g. for Grafana."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    ForEach(BackupServerMetricServer.Kind.allCases) { kind in
                        Button(kind.title) { creating = kind }
                            .accessibilityIdentifier("metrics.add.\(kind.rawValue)")
                    }
                }
                .disabled(!settings.canModify)
                .accessibilityIdentifier("metrics.add")
            }
        }
        .refreshable { await settings.loadMetricServers() }
        .task { await settings.loadMetricServers() }
        .sheet(item: $creating) { kind in
            NavigationStack {
                MetricServerEditor(settings: settings, draft: BackupServerMetricServerDraft(kind: kind), digest: nil, isNew: true)
            }
        }
    }
}

private struct MetricServerLoader: View {
    let settings: BackupServerSettings
    let server: BackupServerMetricServer
    @State private var loaded: Digested<BackupServerRealmConfig>?
    @State private var errorMessage: String?

    var body: some View {
        if let loaded, let kind = server.kind {
            MetricServerEditor(settings: settings, draft: BackupServerMetricServerDraft(kind: kind, name: server.name, config: loaded.value), digest: loaded.digest, isNew: false)
        } else if let errorMessage {
            ContentUnavailableView("Cannot Load the Server", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else {
            ProgressView()
                .task {
                    do {
                        loaded = try await settings.metricServerConfig(server)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
        }
    }
}

private struct MetricServerEditor: View {
    let settings: BackupServerSettings
    private let original: BackupServerMetricServerDraft
    private let digest: String?
    private let isNew: Bool
    @State private var draft: BackupServerMetricServerDraft

    init(settings: BackupServerSettings, draft: BackupServerMetricServerDraft, digest: String?, isNew: Bool) {
        self.settings = settings
        original = draft
        self.digest = digest
        self.isNew = isNew
        _draft = State(initialValue: draft)
    }

    var body: some View {
        BackupServerJobForm(title: isNew ? String(localized: "New Metric Server") : draft.name, isNew: isNew, lockMessage: settings.canModify ? nil : settingsLock,
                            hasChanges: !draft.update(from: original, digest: nil).isEmpty, problems: problems,
                            submit: save, delete: deleteAction,
                            deleteTitle: "Delete Metric Server", deleteMessage: "Metrics are no longer sent to it.", content: formContent)
    }

    private func problems() -> [String: String] { draft.problems(isNew: isNew) }

    private var deleteAction: (() async throws(ConfigUpdateError) -> Void)? {
        guard !isNew else { return nil }
        return { () async throws(ConfigUpdateError) in try await remove() }
    }

    @ViewBuilder
    private func formContent(_ errors: [String: String]) -> some View {
        Section {
            if isNew {
                LabeledTextField(title: "Name", prompt: "influx", text: $draft.name, identifier: "metrics.name")
                FieldError(message: errors["name"])
            }
            Toggle("Enabled", isOn: $draft.isEnabled)
            LabeledTextField(title: "Comment", prompt: "None", text: $draft.comment)
        }
        switch draft.kind {
        case .influxDBHTTP:
            Section {
                LabeledTextField(title: "URL", prompt: "https://influx.lan:8086", text: $draft.url, keyboard: .URL, identifier: "metrics.url")
                FieldError(message: errors["url"])
                LabeledTextField(title: "Organization", prompt: "proxmox", text: $draft.organization)
                LabeledTextField(title: "Bucket", prompt: "proxmox", text: $draft.bucket)
                LabeledContent(isNew ? "Token" : "New Token") {
                    SecureField("Token", text: $draft.token, prompt: Text(isNew ? "None" : "Unchanged"))
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Verify Certificate", isOn: $draft.verifiesTLS)
                OptionalNumberField(title: "Max. Body Size", placeholder: "25000000", value: $draft.maxBodySize)
            } header: {
                Text("InfluxDB 2")
            } footer: {
                Text("For InfluxDB 1.8, use the database as bucket and user:password as token.")
            }
        case .influxDBUDP:
            Section {
                LabeledTextField(title: "Host", prompt: "influx.lan:8089", text: $draft.host, keyboard: .URL, identifier: "metrics.host")
                FieldError(message: errors["host"])
                OptionalNumberField(title: "MTU", placeholder: "1500", value: $draft.mtu)
            } header: {
                Text("InfluxDB")
            }
        }
    }

    private func save() async throws(ConfigUpdateError) {
        if isNew {
            try await settings.createMetricServer(draft)
        } else {
            try await settings.updateMetricServer(draft.kind, draft.name, draft.update(from: original, digest: digest))
        }
    }

    private func remove() async throws(ConfigUpdateError) {
        try await settings.deleteMetricServer(draft.kind, draft.name)
    }
}

// MARK: - S3 endpoints

/// S3-compatible object stores that datastores can keep their chunks in.
struct S3EndpointsView: View {
    let settings: BackupServerSettings
    @State private var creating = false

    var body: some View {
        List {
            ForEach(settings.s3Endpoints ?? []) { endpoint in
                NavigationLink {
                    S3EndpointEditor(settings: settings, endpoint: endpoint)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.id).font(.body.weight(.medium))
                        Text([endpoint.endpoint, endpoint.region].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("s3.\(endpoint.id)")
            }
        }
        .navigationTitle("S3 Endpoints")
        .overlay {
            if settings.s3Endpoints == nil {
                ProgressView()
            } else if settings.s3Endpoints?.isEmpty == true {
                ContentUnavailableView("No S3 Endpoints", systemImage: "cloud",
                                       description: Text("Add an S3-compatible store, such as MinIO, Ceph or AWS, to keep datastores in buckets."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!settings.canModify)
                    .accessibilityIdentifier("s3.add")
            }
        }
        .refreshable { await settings.loadS3Endpoints() }
        .task { await settings.loadS3Endpoints() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                S3EndpointEditor(settings: settings, endpoint: nil)
            }
        }
    }
}

private struct S3EndpointEditor: View {
    let settings: BackupServerSettings
    let endpoint: S3Endpoint?
    private let original: S3EndpointDraft
    @State private var draft: S3EndpointDraft
    @State private var check: Result<[String], ConfigUpdateError>?
    @State private var isChecking = false

    init(settings: BackupServerSettings, endpoint: S3Endpoint?) {
        self.settings = settings
        self.endpoint = endpoint
        original = endpoint.map(S3EndpointDraft.init) ?? S3EndpointDraft()
        _draft = State(initialValue: original)
    }

    private var isNew: Bool { endpoint == nil }

    var body: some View {
        BackupServerJobForm(title: endpoint?.id ?? String(localized: "New S3 Endpoint"), isNew: isNew, lockMessage: settings.canModify ? nil : settingsLock,
                            hasChanges: !draft.update(from: original, digest: nil).isEmpty, problems: problems,
                            submit: save, delete: deleteAction,
                            deleteTitle: "Delete Endpoint", deleteMessage: "Datastores in its buckets can no longer reach them.", content: formContent)
    }

    private func problems() -> [String: String] { draft.problems(isNew: isNew) }

    private var deleteAction: (() async throws(ConfigUpdateError) -> Void)? {
        guard !isNew else { return nil }
        return { () async throws(ConfigUpdateError) in try await remove() }
    }

    @ViewBuilder
    private func formContent(_ errors: [String: String]) -> some View {
        Section {
            if isNew {
                LabeledTextField(title: "ID", prompt: "minio", text: $draft.id, identifier: "s3.id")
                FieldError(message: errors["id"])
            }
            LabeledTextField(title: "Endpoint", prompt: "s3.example.net", text: $draft.endpoint, keyboard: .URL, identifier: "s3.endpoint")
            FieldError(message: errors["endpoint"])
            OptionalNumberField(title: "Port", placeholder: "443", value: $draft.port)
            FieldError(message: errors["port"])
            LabeledTextField(title: "Region", prompt: "us-east-1", text: $draft.region)
            Toggle("Path Style", isOn: $draft.usesPathStyle)
        } footer: {
            Text("The endpoint may contain {{bucket}} and {{region}}. Path style addresses buckets as paths, as MinIO and Ceph need.")
        }
        Section {
            LabeledTextField(title: "Access Key", prompt: "Required", text: $draft.accessKey, identifier: "s3.accessKey")
            FieldError(message: errors["access-key"])
            LabeledContent(isNew ? "Secret Key" : "New Secret Key") {
                SecureField("Secret Key", text: $draft.secretKey, prompt: Text(isNew ? "Required" : "Unchanged"))
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("s3.secretKey")
            }
            FieldError(message: errors["secret-key"])
        } header: {
            Text("Credentials")
        }
        Section {
            TextField("Fingerprint", text: $draft.fingerprint, prompt: Text("Not needed for trusted certificates"), axis: .vertical)
                .font(.footnote.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Skip If-None-Match Header", isOn: $draft.skipsIfNoneMatch)
            if settings.connection.supports(backupServer: .s3RateLimits) {
                OptionalNumberField(title: "PUT Requests/s", placeholder: "Unlimited", value: $draft.putRateLimit)
                ByteRateField(title: "Rate In", rate: $draft.rateIn)
                ByteRateField(title: "Rate Out", rate: $draft.rateOut)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Some providers do not support the If-None-Match header. The fingerprint is needed for self-signed certificates.")
        }
        if let endpoint {
            Section {
                Button {
                    Task {
                        isChecking = true
                        check = await settings.buckets(of: endpoint.id)
                        isChecking = false
                    }
                } label: {
                    HStack {
                        Label("List Buckets", systemImage: "tray.2")
                        if isChecking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isChecking)
                .accessibilityIdentifier("s3.check")
                switch check {
                case .success(let buckets):
                    Label(buckets.isEmpty ? String(localized: "Connected. No buckets.") : String(localized: "Connected. Buckets: \(buckets.joined(separator: ", "))"),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                case .failure(let error):
                    Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                case nil:
                    EmptyView()
                }
            } footer: {
                Text("Signs in with the saved settings, which also checks them.")
            }
        }
    }

    private func save() async throws(ConfigUpdateError) {
        if let endpoint {
            try await settings.updateS3Endpoint(endpoint.id, draft.update(from: original, digest: nil))
        } else {
            try await settings.createS3Endpoint(draft)
        }
    }

    private func remove() async throws(ConfigUpdateError) {
        if let endpoint { try await settings.deleteS3Endpoint(endpoint.id) }
    }
}

// MARK: - Encryption keys

/// Keys sync jobs encrypt pushed snapshots with, and decrypt pulled ones with (4.2 and newer).
struct EncryptionKeysView: View {
    let settings: BackupServerSettings
    @State private var creating = false
    @State private var archiving: EncryptionKeyEntry?
    @State private var deleting: EncryptionKeyEntry?
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(settings.encryptionKeys ?? []) { key in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(key.id).font(.body.weight(.medium))
                        if key.isArchived {
                            Text("Archived")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15), in: .capsule)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let fingerprint = key.fingerprint {
                        Text(fingerprint).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if let created = key.created {
                        Text("Created \(created.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("key.\(key.id)")
                .swipeActions {
                    if settings.canModify {
                        Button("Delete", systemImage: "trash") { deleting = key }
                            .tint(.red)
                        if !key.isArchived {
                            Button("Archive", systemImage: "archivebox") { archiving = key }
                                .tint(.orange)
                        }
                    }
                }
            }
        }
        .navigationTitle("Encryption Keys")
        .overlay {
            if settings.encryptionKeys == nil {
                ProgressView()
            } else if settings.encryptionKeys?.isEmpty == true {
                ContentUnavailableView("No Encryption Keys", systemImage: "key",
                                       description: Text("Sync jobs can encrypt what they push to another server with a key kept here."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!settings.canModify)
                    .accessibilityIdentifier("key.add")
            }
        }
        .refreshable { await settings.loadEncryptionKeys() }
        .task { await settings.loadEncryptionKeys() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                NewEncryptionKeyView(settings: settings)
            }
        }
        .confirmationDialog("Archive \(archiving?.id ?? "")?", isPresented: Binding(get: { archiving != nil }, set: { if !$0 { archiving = nil } }),
                            titleVisibility: .visible, presenting: archiving) { key in
            Button("Archive") { run { try await settings.archiveEncryptionKey(key.id) } }
        } message: { _ in
            Text("Sync jobs no longer encrypt with it, but it still decrypts snapshots encrypted before.")
        }
        .confirmationDialog("Delete \(deleting?.id ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { key in
            Button("Delete Key", role: .destructive) { run { try await settings.deleteEncryptionKey(key.id) } }
        } message: { _ in
            Text("Snapshots encrypted with it cannot be decrypted without a copy of the key.")
        }
        .alert("Encryption Key Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct NewEncryptionKeyView: View {
    let settings: BackupServerSettings
    @State private var id = ""
    @State private var importedKey = ""
    @State private var imports = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        id.count >= 3 && id.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._\-]*/) != nil && (!imports || !importedKey.isEmpty)
    }

    var body: some View {
        Form {
            Section {
                LabeledTextField(title: "ID", prompt: "offsite-2026", text: $id, identifier: "key.id")
                Toggle("Import Existing Key", isOn: $imports)
                if imports {
                    TextField("Key", text: $importedKey, prompt: Text("The key file's JSON"), axis: .vertical)
                        .font(.footnote.monospaced())
                        .lineLimit(4...10)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } footer: {
                Text(imports
                    ? "Imports a key made with proxmox-backup-client key create, e.g. to decrypt snapshots pulled from another server."
                    : "The server makes a new key and keeps it. Keep a copy elsewhere too: without the key, encrypted snapshots are lost.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("New Encryption Key")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Create", isWorking: isSaving) { Task { await create() } }
                    .disabled(!isValid)
                    .accessibilityIdentifier("key.create")
            }
        }
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await settings.createEncryptionKey(id.trimmingCharacters(in: .whitespaces), importing: imports ? importedKey : nil)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
