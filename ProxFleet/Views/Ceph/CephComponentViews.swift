import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Shows a failed Ceph action, shared by the Ceph screens.
private struct CephErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("Ceph Error", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
    }
}

extension View {
    fileprivate func cephErrorAlert(_ message: Binding<String?>) -> some View {
        modifier(CephErrorAlert(message: message))
    }
}

// MARK: - Monitors, managers and metadata servers

struct CephServicesView: View {
    let manager: CephManager
    @State private var adding: CephService.Kind?
    @State private var pending: (kind: CephService.Kind, service: CephService, action: String, warning: String?)?
    @State private var busy: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(CephService.Kind.allCases) { kind in
                Section {
                    let services = manager.services[kind] ?? []
                    if services.isEmpty {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(services) { service in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                Text([service.host, service.version, service.fileSystem].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if busy == "\(kind.rawValue).\(service.name)" {
                                ProgressView()
                            } else {
                                CephStateBadge(state: service.state, isGood: service.isRunning && service.inQuorum != false)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("ceph.\(kind.rawValue).\(service.name)")
                        .contextMenu {
                            Button("Start", systemImage: "play") { Task { await ask(kind, service, "start") } }
                            Button("Stop", systemImage: "stop") { Task { await ask(kind, service, "stop") } }
                            Button("Restart", systemImage: "arrow.clockwise") { Task { await ask(kind, service, "restart") } }
                            Button("Destroy", systemImage: "trash", role: .destructive) { Task { await ask(kind, service, "destroy") } }
                        }
                        .swipeActions {
                            Button("Destroy", systemImage: "trash") { Task { await ask(kind, service, "destroy") } }
                                .tint(.red)
                            Button("Restart", systemImage: "arrow.clockwise") { Task { await ask(kind, service, "restart") } }
                                .tint(.blue)
                        }
                    }
                } header: {
                    Text(Self.title(kind))
                } footer: {
                    Text(Self.footer(kind))
                }
            }
        }
        .navigationTitle("Monitors & Managers")
        .task { await manager.keepRefreshing() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("Monitor") { adding = .monitor }
                    Button("Manager") { adding = .manager }
                    Button("Metadata Server") { adding = .metadataServer }
                }
                .accessibilityIdentifier("ceph.service.add")
            }
        }
        .refreshable { await manager.load() }
        .sheet(item: $adding) { kind in
            NavigationStack {
                CephServiceCreateView(manager: manager, kind: kind)
            }
        }
        .confirmationDialog(
            pending.map { "\($0.action.capitalized) \($0.kind.rawValue).\($0.service.name)?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending
        ) { pending in
            Button(pending.action.capitalized, role: ["stop", "destroy"].contains(pending.action) ? .destructive : nil) {
                Task { await run(pending.kind, pending.service, pending.action) }
            }
            .accessibilityIdentifier("ceph.service.confirm")
        } message: { pending in
            Text(pending.warning ?? (pending.action == "destroy" ? String(localized: "The service is removed from its node.") : ""))
        }
        .cephErrorAlert($errorMessage)
    }

    static func title(_ kind: CephService.Kind) -> LocalizedStringKey {
        switch kind {
        case .monitor: "Monitors"
        case .manager: "Managers"
        case .metadataServer: "Metadata Servers"
        }
    }

    static func footer(_ kind: CephService.Kind) -> LocalizedStringKey {
        switch kind {
        case .monitor: "Monitors keep the cluster map. Three or more keep a quorum when one fails."
        case .manager: "One manager is active; the others stand by."
        case .metadataServer: "CephFS needs a metadata server; more stand by to take over."
        }
    }

    /// Stopping or destroying asks Proxmox first whether it is safe.
    private func ask(_ kind: CephService.Kind, _ service: CephService, _ action: String) async {
        var warning: String?
        if ["stop", "destroy"].contains(action), kind != .manager,
           let check = await manager.safety(of: kind.rawValue, id: service.name, action: action, host: service.host), !check.isSafe {
            warning = check.status
        }
        pending = (kind, service, action, warning)
    }

    private func run(_ kind: CephService.Kind, _ service: CephService, _ action: String) async {
        busy = "\(kind.rawValue).\(service.name)"
        defer { busy = nil }
        do {
            if action == "destroy" {
                try await manager.destroy(kind, service)
            } else {
                try await manager.perform(action, service: "\(kind.rawValue).\(service.name)", host: service.host)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CephStateBadge: View {
    let state: String
    let isGood: Bool

    var body: some View {
        Text(state)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((isGood ? Color.green : Color.orange).opacity(0.18), in: .capsule)
            .foregroundStyle(isGood ? Color.green : Color.orange)
    }
}

private struct CephServiceCreateView: View {
    let manager: CephManager
    let kind: CephService.Kind
    @State private var host: String
    @State private var id = ""
    @State private var hotStandby = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(manager: CephManager, kind: CephService.Kind) {
        self.manager = manager
        self.kind = kind
        let existing = Set((manager.services[kind] ?? []).map(\.host))
        let nodes = manager.connection.snapshot?.nodes.filter(\.isOnline).map(\.name) ?? [manager.node]
        _host = State(initialValue: nodes.first { !existing.contains($0) } ?? manager.node)
    }

    var body: some View {
        Form {
            Section {
                Picker("Host", selection: $host) {
                    ForEach(manager.connection.snapshot?.nodes.filter(\.isOnline).map(\.name) ?? [manager.node], id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("ceph.service.host")
                if kind == .metadataServer {
                    LabeledContent("MDS ID") {
                        TextField("ID", text: $id, prompt: Text(host))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Toggle("Hot Standby", isOn: $hotStandby)
                }
            } footer: {
                Text(kind == .metadataServer
                    ? "Hot standby follows the active metadata server's journal, so it takes over faster."
                    : "The node needs the Ceph packages installed.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(kind == .monitor ? "Create Monitor" : kind == .manager ? "Create Manager" : "Create Metadata Server")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Create", isWorking: isWorking) { Task { await create() } }
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func create() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let id = id.trimmingCharacters(in: .whitespaces)
            try await manager.create(kind, on: host, id: id.isEmpty ? nil : id, hotStandby: hotStandby)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - OSDs

struct CephOSDsView: View {
    let manager: CephManager
    @State private var adding = false

    var body: some View {
        List {
            if let tree = manager.osdTree {
                let setFlags = (manager.flags ?? []).filter(\.isSet)
                Section {
                    NavigationLink {
                        CephFlagsView(manager: manager)
                    } label: {
                        MoreRow(title: "Global Flags", systemImage: "flag", color: setFlags.isEmpty ? .gray : .orange, hint: setFlags.isEmpty ? String(localized: "None") : setFlags.map(\.name).joined(separator: ", "))
                    }
                    .accessibilityIdentifier("ceph.flags")
                }
                ForEach(tree.hosts, id: \.self) { host in
                    Section(host) {
                        let osds = tree.osds.filter { $0.host == host }
                        if osds.isEmpty {
                            Text("No OSDs")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(osds) { osd in
                            NavigationLink {
                                CephOSDDetailView(manager: manager, id: osd.id)
                            } label: {
                                CephOSDRow(osd: osd)
                            }
                            .accessibilityIdentifier("ceph.osd.\(osd.id)")
                        }
                    }
                }
            }
        }
        .overlay {
            if manager.osdTree?.osds.isEmpty == true {
                ContentUnavailableView("No OSDs", systemImage: "internaldrive", description: Text("An OSD stores data on a disk. Create one on an unused disk of each node."))
            }
        }
        .navigationTitle("OSDs")
        .task { await manager.keepRefreshing() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Create OSD", systemImage: "plus") { adding = true }
                    .accessibilityIdentifier("ceph.osd.add")
            }
        }
        .refreshable { await manager.load() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                CephOSDCreateView(manager: manager)
            }
        }
    }
}

private struct CephOSDRow: View {
    let osd: CephOSD

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(osd.name)
                    if let deviceClass = osd.deviceClass {
                        Text(deviceClass)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: min(osd.percentUsed / 100, 1))
                    .frame(maxWidth: 160)
                Text("\(Format.bytes(osd.bytesUsed)) of \(Format.bytes(osd.totalSpace))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                CephStateBadge(state: osd.isUp ? "up" : "down", isGood: osd.isUp)
                CephStateBadge(state: osd.isIn ? "in" : "out", isGood: osd.isIn)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CephOSDDetailView: View {
    let manager: CephManager
    let id: Int
    @State private var confirmsDestroy = false
    @State private var cleanup = true
    @State private var pendingStop: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var osd: CephOSD? { manager.osdTree?.osds.first { $0.id == id } }

    var body: some View {
        Form {
            if let osd {
                Section {
                    LabeledContent("Host", value: osd.host)
                    LabeledContent("Status", value: "\(osd.isUp ? "up" : "down"), \(osd.isIn ? "in" : "out")")
                    LabeledContent("Device Class", value: osd.deviceClass ?? "–")
                    LabeledContent("Used", value: "\(Format.bytes(osd.bytesUsed)) of \(Format.bytes(osd.totalSpace))")
                    LabeledContent("Placement Groups", value: String(osd.placementGroups))
                    LabeledContent("Latency (Apply/Commit)", value: "\(osd.applyLatency) / \(osd.commitLatency) ms")
                    if let version = osd.version { LabeledContent("Version", value: version) }
                    if let db = osd.databaseDevice { LabeledContent("DB Device", value: db) }
                    if let wal = osd.walDevice { LabeledContent("WAL Device", value: wal) }
                }
                Section {
                    Button(osd.isIn ? "Mark Out" : "Mark In", systemImage: osd.isIn ? "arrow.right.circle" : "arrow.left.circle") {
                        Task { await run { try await manager.set(osd, in: !osd.isIn) } }
                    }
                    .accessibilityIdentifier("ceph.osd.inout")
                    if osd.isUp {
                        Button("Stop", systemImage: "stop") { Task { await askStop(osd) } }
                            .accessibilityIdentifier("ceph.osd.stop")
                        Button("Restart", systemImage: "arrow.clockwise") {
                            Task { await run { try await manager.perform("restart", service: osd.name, host: osd.host) } }
                        }
                    } else {
                        Button("Start", systemImage: "play") {
                            Task { await run { try await manager.perform("start", service: osd.name, host: osd.host) } }
                        }
                        .accessibilityIdentifier("ceph.osd.start")
                    }
                    Button("Scrub", systemImage: "sparkle.magnifyingglass") { Task { await run { try await manager.scrub(osd, deep: false) } } }
                    Button("Deep Scrub", systemImage: "magnifyingglass") { Task { await run { try await manager.scrub(osd, deep: true) } } }
                } footer: {
                    Text("Out moves the OSD's data to other OSDs. Scrubbing compares the copies; a deep scrub reads all data.")
                }
                Section {
                    Toggle("Clean Up Disks", isOn: $cleanup)
                    Button("Destroy OSD", systemImage: "trash", role: .destructive) { confirmsDestroy = true }
                        .disabled(osd.isUp || osd.isIn)
                        .accessibilityIdentifier("ceph.osd.destroy")
                } footer: {
                    Text(osd.isUp || osd.isIn
                        ? "Mark the OSD out, wait until its data has moved, then stop it to destroy it."
                        : "Cleaning up wipes the OSD's disks, so they can be used again.")
                }
            } else {
                ContentUnavailableView("OSD Removed", systemImage: "internaldrive")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("osd.\(id)")
        .task { await manager.keepRefreshing() }
        .disabled(isWorking)
        .overlay { if isWorking { ProgressView() } }
        .confirmationDialog("Stop osd.\(id)?", isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }), titleVisibility: .visible) {
            Button("Stop", role: .destructive) {
                guard let osd else { return }
                Task { await run { try await manager.perform("stop", service: osd.name, host: osd.host) } }
            }
        } message: {
            Text(pendingStop ?? "")
        }
        .confirmationDialog("Destroy osd.\(id)?", isPresented: $confirmsDestroy, titleVisibility: .visible) {
            Button("Destroy", role: .destructive) {
                guard let osd else { return }
                Task {
                    await run { try await manager.destroy(osd, cleanup: cleanup) }
                    if errorMessage == nil { dismiss() }
                }
            }
            .accessibilityIdentifier("ceph.osd.destroy.confirm")
        } message: {
            Text("The OSD and its data on this disk are removed from the cluster.")
        }
    }

    private func askStop(_ osd: CephOSD) async {
        let check = await manager.safety(of: "osd", id: String(osd.id), action: "stop", host: osd.host)
        pendingStop = check.flatMap { $0.isSafe ? nil : $0.status } ?? String(localized: "Its placement groups stay available on other OSDs.")
    }

    private func run(_ action: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CephOSDCreateView: View {
    let manager: CephManager
    @State private var host: String
    @State private var draft = CephOSDDraft()
    @State private var disks: [NodeDisk] = []
    @State private var errors: [String: String] = [:]
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(manager: CephManager) {
        self.manager = manager
        _host = State(initialValue: manager.node)
    }

    var body: some View {
        Form {
            Section {
                Picker("Host", selection: $host) {
                    ForEach(manager.connection.snapshot?.nodes.filter(\.isOnline).map(\.name) ?? [manager.node], id: \.self) { Text($0).tag($0) }
                }
                Picker("Disk", selection: $draft.device) {
                    Text(disks.isEmpty ? "No Unused Disk" : "Choose").tag("")
                    ForEach(disks) { disk in Text(Self.label(disk)).tag(disk.path) }
                }
                .accessibilityIdentifier("ceph.osd.disk")
                FieldError(message: errors["dev"])
                Picker("Device Class", selection: $draft.deviceClass) {
                    Text("Detect").tag("")
                    Text("HDD").tag("hdd")
                    Text("SSD").tag("ssd")
                    Text("NVMe").tag("nvme")
                }
                Toggle("Encrypt", isOn: $draft.encrypted)
            } footer: {
                Text("The disk is wiped and used whole for the OSD.")
            }
            Section {
                Picker("DB Disk", selection: $draft.databaseDevice) {
                    Text("OSD Disk").tag("")
                    ForEach(disks.filter { $0.path != draft.device }) { disk in Text(Self.label(disk)).tag(disk.path) }
                }
                FieldError(message: errors["db_dev"])
                if !draft.databaseDevice.isEmpty {
                    LabeledTextField(title: "DB Size (GiB)", prompt: "Automatic", text: $draft.databaseSize, keyboard: .decimalPad)
                    FieldError(message: errors["db_dev_size"])
                }
                Picker("WAL Disk", selection: $draft.walDevice) {
                    Text("OSD or DB Disk").tag("")
                    ForEach(disks.filter { $0.path != draft.device }) { disk in Text(Self.label(disk)).tag(disk.path) }
                }
                FieldError(message: errors["wal_dev"])
                if !draft.walDevice.isEmpty {
                    LabeledTextField(title: "WAL Size (GiB)", prompt: "Automatic", text: $draft.walSize, keyboard: .decimalPad)
                    FieldError(message: errors["wal_dev_size"])
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("A faster disk for the database (DB) and write-ahead log (WAL) speeds up an OSD on a slow disk.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Create OSD")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .task(id: host) {
            disks = await manager.unusedDisks(on: host)
            if !disks.contains(where: { $0.path == draft.device }) { draft.device = disks.first?.path ?? "" }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Create", isWorking: isWorking) { Task { await create() } }
                    .accessibilityIdentifier("save")
            }
        }
    }

    static func label(_ disk: NodeDisk) -> String {
        "\(disk.path) · \(Format.bytes(disk.size))\(disk.model.map { " · \($0)" } ?? "")"
    }

    private func create() async {
        errors = draft.problems
        guard errors.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await manager.createOSD(on: host, draft)
            dismiss()
        } catch .invalid(let message, let fields) {
            errors = fields
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CephFlagsView: View {
    let manager: CephManager
    @State private var values: [String: Bool] = [:]
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var changes: [String: Bool] {
        values.filter { name, value in manager.flags?.first { $0.name == name }?.isSet != value }
    }

    var body: some View {
        Form {
            Section {
                ForEach(manager.flags ?? []) { flag in
                    Toggle(isOn: Binding(get: { values[flag.name] ?? flag.isSet }, set: { values[flag.name] = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(flag.name)
                                .font(.body.monospaced())
                            Text(flag.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("ceph.flag.\(flag.name)")
                }
            } footer: {
                Text("Flags pause parts of Ceph's self-healing, e.g. noout during maintenance, so OSDs that go down are not marked out. Clear them afterwards.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Global Flags")
        .disabled(isWorking)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Apply", isWorking: isWorking) { Task { await apply() } }
                    .disabled(changes.isEmpty)
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func apply() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await manager.setFlags(changes)
            values = [:]
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Pools

struct CephPoolsView: View {
    let manager: CephManager
    @State private var adding = false

    var body: some View {
        List {
            ForEach(manager.pools ?? []) { pool in
                NavigationLink {
                    CephPoolEditor(manager: manager, pool: pool)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(pool.name)
                            Spacer()
                            Text(pool.applications.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: min(pool.percentUsed / 100, 1))
                        Text("\(pool.size)/\(pool.minSize) · \(pool.placementGroups) PGs · \(Format.bytes(pool.bytesUsed)) · \(pool.crushRule)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .accessibilityIdentifier("ceph.pool.\(pool.name)")
            }
        }
        .overlay {
            if manager.pools?.isEmpty == true {
                ContentUnavailableView("No Pools", systemImage: "cylinder.split.1x2", description: Text("A pool holds data, like VM disks as RBD images. Create one and add it as storage."))
            }
        }
        .navigationTitle("Pools")
        .task { await manager.keepRefreshing() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Create Pool", systemImage: "plus") { adding = true }
                    .accessibilityIdentifier("ceph.pool.add")
            }
        }
        .refreshable { await manager.load() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                CephPoolEditor(manager: manager, pool: nil)
            }
        }
    }
}

private struct CephPoolEditor: View {
    let manager: CephManager
    let pool: CephPool?
    @State private var draft: CephPoolDraft
    private let original: CephPoolDraft
    @State private var errors: [String: String] = [:]
    @State private var confirmsDestroy = false
    @State private var removeStorages = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(manager: CephManager, pool: CephPool?) {
        self.manager = manager
        self.pool = pool
        let draft = pool.map(CephPoolDraft.init) ?? CephPoolDraft()
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { pool == nil }

    var body: some View {
        Form {
            Section {
                if isNew {
                    LabeledContent("Name") {
                        TextField("Name", text: $draft.name, prompt: Text("vm-pool"))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("ceph.pool.name")
                    }
                    FieldError(message: errors["name"])
                }
                Stepper("Size: \(draft.size)", value: $draft.size, in: 1...7)
                FieldError(message: errors["size"])
                Stepper("Min. Size: \(draft.minSize)", value: $draft.minSize, in: 1...max(1, draft.size))
                FieldError(message: errors["min_size"])
                if draft.warnsAboutMinSize {
                    Label("A min. size of 1 is not recommended and can lead to data loss.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
                Picker("Crush Rule", selection: $draft.crushRule) {
                    ForEach(Array(Set(manager.rules + [draft.crushRule])).sorted(), id: \.self) { Text($0).tag($0) }
                }
            } footer: {
                Text("Size is the number of copies; Min. Size the copies that must be available to write.")
            }
            Section {
                Picker("Autoscaler", selection: $draft.autoscaleMode) {
                    Text("On").tag("on")
                    Text("Warn").tag("warn")
                    Text("Off").tag("off")
                }
                LabeledTextField(title: "Placement Groups", prompt: "128", text: $draft.placementGroups, keyboard: .numberPad, identifier: "ceph.pool.pgs")
                FieldError(message: errors["pg_num"])
                LabeledTextField(title: "Min. Placement Groups", prompt: "0", text: $draft.placementGroupsMinimum, keyboard: .numberPad)
                LabeledTextField(title: "Target Ratio", prompt: "0.0", text: $draft.targetSizeRatio, keyboard: .decimalPad)
                FieldError(message: errors["target_size_ratio"])
                LabeledTextField(title: "Target Size (GiB)", prompt: "0", text: $draft.targetSizeGiB, keyboard: .decimalPad)
                FieldError(message: errors["target_size"])
            } header: {
                Text("Placement Groups")
            } footer: {
                Text("The autoscaler sets the number of placement groups from the pool's expected share of the cluster: Target Ratio, or else Target Size.")
            }
            if isNew {
                Section {
                    Picker("Application", selection: $draft.application) {
                        Text("RBD (VM and CT Disks)").tag("rbd")
                        Text("CephFS").tag("cephfs")
                        Text("RGW (Object Gateway)").tag("rgw")
                    }
                    Toggle("Add as Storage", isOn: $draft.addStorage)
                        .accessibilityIdentifier("ceph.pool.addStorage")
                } footer: {
                    Text("Add as Storage creates an RBD storage of the same name for the whole cluster.")
                }
            } else if let pool {
                Section {
                    LabeledContent("Used", value: "\(Format.bytes(pool.bytesUsed)) (\(pool.percentUsed.formatted(.number.precision(.fractionLength(1))))%)")
                    if let target = pool.placementGroupsTarget, target != pool.placementGroups {
                        LabeledContent("Autoscaler Target", value: String(localized: "\(target) PGs"))
                    }
                    LabeledContent("Applications", value: pool.applications.joined(separator: ", "))
                }
                Section {
                    Toggle("Remove Its Storages", isOn: $removeStorages)
                    Button("Destroy Pool", systemImage: "trash", role: .destructive) { confirmsDestroy = true }
                        .accessibilityIdentifier("ceph.pool.destroy")
                } footer: {
                    Text("Destroying a pool deletes all data in it.")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? "Create Pool" : pool?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .onChange(of: draft.size) { draft.minSize = min(draft.minSize, draft.size) }
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton(isNew ? "Create" : "Save", isWorking: isWorking) { Task { await save() } }
                    .disabled(!isNew && draft.changes(from: original).items.isEmpty)
                    .accessibilityIdentifier("save")
            }
        }
        .confirmationDialog("Destroy pool \(pool?.name ?? "")?", isPresented: $confirmsDestroy, titleVisibility: .visible) {
            Button("Destroy", role: .destructive) { Task { await destroy() } }
                .accessibilityIdentifier("ceph.pool.destroy.confirm")
        } message: {
            Text("All data in the pool is deleted. This cannot be undone.")
        }
    }

    private func save() async {
        errors = draft.problems
        guard errors.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            if let pool {
                try await manager.updatePool(pool.name, draft.changes(from: original))
            } else {
                try await manager.createPool(draft)
            }
            dismiss()
        } catch .invalid(let message, let fields) {
            errors = fields
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func destroy() async {
        guard let pool else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await manager.destroyPool(pool.name, removeStorages: removeStorages)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - CephFS

struct CephFileSystemsView: View {
    let manager: CephManager
    @State private var adding = false

    private var metadataServers: [CephService] { manager.services[.metadataServer] ?? [] }

    var body: some View {
        List {
            Section {
                if manager.fileSystems?.isEmpty ?? true {
                    Text("No file systems")
                        .foregroundStyle(.secondary)
                }
                ForEach(manager.fileSystems ?? []) { fileSystem in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileSystem.name)
                        Text(String(localized: "Data: \(fileSystem.dataPools.joined(separator: ", ")) · Metadata: \(fileSystem.metadataPool)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ceph.fs.\(fileSystem.name)")
                }
            } footer: {
                Text("CephFS stores files, such as ISO images, backups and container templates, for every node.")
            }
            Section {
                if metadataServers.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                ForEach(metadataServers) { server in
                    HStack {
                        Text(server.name)
                        Spacer()
                        CephStateBadge(state: server.state, isGood: server.isRunning)
                    }
                }
            } header: {
                Text("Metadata Servers")
            } footer: {
                if metadataServers.isEmpty {
                    Text("Create a metadata server under Monitors & Managers first.")
                }
            }
        }
        .navigationTitle("CephFS")
        .task { await manager.keepRefreshing() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Create CephFS", systemImage: "plus") { adding = true }
                    .disabled(metadataServers.isEmpty)
                    .accessibilityIdentifier("ceph.fs.add")
            }
        }
        .refreshable { await manager.load() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                CephFileSystemCreateView(manager: manager)
            }
        }
    }
}

private struct CephFileSystemCreateView: View {
    let manager: CephManager
    @State private var name = "cephfs"
    @State private var placementGroups = 128
    @State private var addStorage = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ceph.fs.name")
                }
                Picker("Placement Groups", selection: $placementGroups) {
                    ForEach([8, 16, 32, 64, 128, 256, 512], id: \.self) { Text(String($0)).tag($0) }
                }
                Toggle("Add as Storage", isOn: $addStorage)
            } footer: {
                Text("Creates the data and metadata pools, \(name)_data and \(name)_metadata. Add as Storage makes it a CephFS storage for the whole cluster.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Create CephFS")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Create", isWorking: isWorking) { Task { await create() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func create() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await manager.createFileSystem(name: name.trimmingCharacters(in: .whitespaces), placementGroups: placementGroups, addStorage: addStorage)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Configuration and log

struct CephConfigurationView: View {
    let manager: CephManager
    @State private var part = 0
    @State private var file: String?
    @State private var database: [CephConfigEntry]?
    @State private var crush: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Part", selection: $part) {
                Text("ceph.conf").tag(0)
                Text("Database").tag(1)
                Text("CRUSH Map").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()
            switch part {
            case 1:
                List(database ?? []) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.body.monospaced())
                        Text("\(entry.section) · \(entry.value)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            default:
                ScrollView([.vertical, .horizontal]) {
                    Text((part == 0 ? file : crush) ?? "")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .overlay {
            if let errorMessage {
                ContentUnavailableView("Cannot Load Configuration", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            }
        }
        .navigationTitle("Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                async let file = manager.configFile()
                async let database = manager.configDatabase()
                async let crush = manager.crushMap()
                self.file = try await file
                self.database = try await database
                self.crush = try await crush
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct CephLogView: View {
    let manager: CephManager
    @State private var lines: [TaskLogLine]?
    @State private var errorMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(lines ?? []) { line in
                        Text(line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.text.contains("[WRN]") ? Color.orange : line.text.contains("[ERR]") ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.number)
                    }
                }
                .padding()
            }
            .onChange(of: lines?.last?.number) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .overlay {
            if let errorMessage, lines == nil {
                ContentUnavailableView("Cannot Load Log", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if lines == nil {
                ProgressView()
            }
        }
        .navigationTitle("Ceph Log")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                do {
                    lines = try await manager.log()
                    errorMessage = nil
                } catch is CancellationError {
                    break
                } catch {
                    errorMessage = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
