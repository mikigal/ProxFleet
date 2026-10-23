import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The web interface's Datacenter > HA: the status of quorum, the CRM and every node's LRM, the guests HA manages,
/// arming and disarming, and the rules.
struct HAView: View {
    @State private var manager: HAManager
    @State private var adding = false
    @State private var removing: HAResource?
    @State private var disarmMode: String?
    @State private var confirmsArm = false
    @State private var errorMessage: String?

    init(connection: ServerConnection) {
        _manager = State(initialValue: HAManager(connection: connection))
    }

    var body: some View {
        List {
            if manager.status != nil {
                statusSection
                resourcesSection
                Section {
                    NavigationLink {
                        HARulesView(manager: manager)
                    } label: {
                        MoreRow(title: "Rules", systemImage: "point.3.filled.connected.trianglepath.dotted", color: .indigo, hint: rulesHint)
                    }
                    .accessibilityIdentifier("ha.rules")
                } footer: {
                    Text("Rules keep resources on preferred nodes, off some nodes, or together or apart.")
                }
            }
        }
        .overlay {
            if !manager.isAvailable {
                ContentUnavailableView("HA Needs a Cluster", systemImage: "shield.lefthalf.filled", description: Text("High availability restarts guests on another node of the cluster when theirs fails."))
            } else if let error = manager.loadError, manager.status == nil {
                ContentUnavailableView("Cannot Load HA", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if manager.status == nil {
                ProgressView()
            }
        }
        .navigationTitle("High Availability")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                armingMenu
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { adding = true }
                    .disabled(!manager.isAvailable)
                    .accessibilityIdentifier("ha.add")
            }
        }
        .refreshable { await manager.load() }
        .task {
            guard manager.isAvailable else { return }
            await manager.load()
            await manager.keepRefreshing()
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                HAResourceEditor(manager: manager, resource: nil, guest: nil)
            }
        }
        .confirmationDialog("Remove from HA?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { resource in
            Button("Remove", role: .destructive) { Task { await remove(resource, purge: true) } }
                .accessibilityIdentifier("ha.remove.confirm")
            Button("Remove, Keep in Rules") { Task { await remove(resource, purge: false) } }
        } message: { resource in
            Text("\(resource.sid) keeps running as it is, but no longer moves when its node fails. Rules left without resources are deleted too, unless it stays in them.")
        }
        .confirmationDialog("Disarm HA?", isPresented: Binding(get: { disarmMode != nil }, set: { if !$0 { disarmMode = nil } }), titleVisibility: .visible, presenting: disarmMode) { mode in
            Button("Disarm", role: .destructive) { Task { await perform { try await manager.disarm(resourceMode: mode) } } }
                .accessibilityIdentifier("ha.disarm.confirm")
        } message: { mode in
            Text(mode == "freeze"
                ? "Every node releases its watchdog and resources keep their state: HA applies no new commands. While disarmed, HA does not recover failures."
                : "Every node releases its watchdog and HA ignores the resources, which can be managed as if HA were off. While disarmed, HA does not recover failures.")
        }
        .alert("Arm HA?", isPresented: $confirmsArm) {
            Button("Cancel", role: .cancel) {}
            Button("Arm") { Task { await perform { try await manager.arm() } } }
        } message: {
            Text("HA protects its resources again.")
        }
        .alert("HA Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var armingMenu: some View {
        Menu("More", systemImage: "ellipsis") {
            if manager.isDisarmed {
                Button("Arm HA", systemImage: "link") { confirmsArm = true }
            } else {
                Menu("Disarm HA", systemImage: "link.badge.plus") {
                    Button("Freeze Resources", systemImage: "snowflake") { disarmMode = "freeze" }
                    Button("Ignore Resources", systemImage: "eye.slash") { disarmMode = "ignore" }
                }
            }
        }
        .disabled(manager.status == nil)
        .accessibilityIdentifier("ha.more")
    }

    private var rulesHint: String? {
        guard let rules = manager.rules else { return nil }
        if rules.contains(where: { !$0.errors.isEmpty }) { return String(localized: "Conflicts") }
        return rules.isEmpty ? String(localized: "None") : String(rules.count)
    }

    private var statusSection: some View {
        Section {
            if let quorum = manager.quorum {
                HAStatusRow(title: "Quorum", value: quorum.isQuorate == false ? String(localized: "No quorum") : quorum.status, isGood: quorum.isQuorate != false, systemImage: "person.3")
            }
            if let master = manager.master {
                HAStatusRow(title: "Manager", value: "\(master.node), \(HAStatusRow.summary(master.status))", isGood: master.status.contains("active"), systemImage: "crown")
            } else {
                HAStatusRow(title: "Manager", value: String(localized: "Idle until a resource is added"), isGood: true, systemImage: "crown")
            }
            if let fencing = manager.fencing {
                HAStatusRow(title: "Fencing", value: Self.armedTitle(fencing), isGood: fencing.armedState != "disarmed", systemImage: "bolt.shield")
                    .accessibilityIdentifier("ha.fencing")
            }
            ForEach(manager.localResourceManagers) { lrm in
                HAStatusRow(title: LocalizedStringKey(lrm.node), value: HAStatusRow.summary(lrm.status), isGood: !lrm.status.contains("dead") && !lrm.status.contains("unknown"), systemImage: "server.rack")
            }
        } header: {
            Text("Status")
        } footer: {
            if manager.hasFewVotes {
                Text("At least three quorum votes are recommended for reliable HA.")
            }
        }
    }

    static func armedTitle(_ fencing: HAStatusEntry) -> String {
        switch fencing.armedState {
        case "armed": String(localized: "Armed")
        case "standby": String(localized: "Standby")
        case "disarming": String(localized: "Disarming…")
        case "disarmed": fencing.resourceMode == "ignore" ? String(localized: "Disarmed, ignoring resources") : String(localized: "Disarmed, resources frozen")
        default: fencing.status
        }
    }

    private var resourcesSection: some View {
        Section {
            let resources = manager.resources ?? []
            if resources.isEmpty {
                Text("No HA resources")
                    .foregroundStyle(.secondary)
            }
            ForEach(resources) { resource in
                NavigationLink {
                    HAResourceEditor(manager: manager, resource: resource, guest: nil)
                } label: {
                    HAResourceRow(resource: resource, service: manager.serviceStatus(of: resource.sid), name: guestName(resource))
                }
                .accessibilityIdentifier("ha.resource.\(resource.sid)")
                .swipeActions {
                    // Not `role: .destructive`: a full swipe would hide the row, but this only asks first.
                    Button("Remove", systemImage: "trash") { removing = resource }
                        .tint(.red)
                }
            }
        } header: {
            Text("Resources")
        } footer: {
            Text("HA starts these guests in their requested state and restarts them on another node when theirs fails.")
        }
    }

    private func guestName(_ resource: HAResource) -> String? {
        manager.connection.snapshot?.guests.first { $0.vmid == resource.vmid }?.name
    }

    private func remove(_ resource: HAResource, purge: Bool) async {
        await perform { try await manager.remove(resource.sid, purgeFromRules: purge) }
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct HAStatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let isGood: Bool
    let systemImage: String

    var body: some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(isGood ? Color.green : Color.orange)
            }
        }
    }

    /// `test3 (active, Fri Oct 23 13:23:47 2026)` without the node name and the time stamp: `active`.
    static func summary(_ status: String) -> String {
        guard let open = status.firstIndex(of: "("), let close = status.lastIndex(of: ")"), open < close else { return status }
        let parts = status[status.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // The time of the last update is the part with a clock time in it.
        let kept = parts.filter { $0.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) == nil }
        return kept.isEmpty ? status : kept.joined(separator: ", ")
    }
}

struct HAResourceRow: View {
    let resource: HAResource
    let service: HAStatusEntry?
    let name: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: resource.kind == .container ? "shippingbox" : "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? resource.sid)
                Text([resource.sid, service?.node].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(service?.state ?? resource.state)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Self.color(service?.state ?? resource.state).opacity(0.18), in: .capsule)
                .foregroundStyle(Self.color(service?.state ?? resource.state))
        }
        .accessibilityElement(children: .combine)
    }

    static func color(_ state: String) -> Color {
        switch state {
        case "started": .green
        case "error", "fence", "recovery": .red
        case "stopped", "disabled", "ignored": .secondary
        default: .orange
        }
    }
}

/// Adds a guest to HA or edits how HA handles it, like the web interface's resource dialog, plus moving it with HA.
struct HAResourceEditor: View {
    let manager: HAManager
    let resource: HAResource?
    @State private var draft: HAResourceDraft
    private let original: HAResourceDraft
    @State private var errors: [String: String] = [:]
    @State private var isSaving = false
    @State private var moving = false
    @State private var confirmsRemoval = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    /// `guest` fixes the guest when adding from its screen.
    init(manager: HAManager, resource: HAResource?, guest: GuestReference?) {
        self.manager = manager
        self.resource = resource
        let draft = resource.map(HAResourceDraft.init) ?? HAResourceDraft(guest: guest?.vmid ?? 0, kind: guest?.kind ?? .virtualMachine)
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { resource == nil }
    private var service: HAStatusEntry? { resource.flatMap { manager.serviceStatus(of: $0.sid) } }

    /// Guests HA does not manage yet, templates aside.
    private var candidates: [GuestSummary] {
        let managed = Set((manager.resources ?? []).compactMap(\.vmid))
        return (manager.connection.snapshot?.guests ?? []).filter { !$0.isTemplate && !managed.contains($0.vmid) }.sorted { $0.vmid < $1.vmid }
    }

    var body: some View {
        Form {
            Section {
                if isNew, draft.guest == 0 || !candidates.contains(where: { $0.vmid == draft.guest }) {
                    Picker("Guest", selection: Binding(get: { draft.guest }, set: { vmid in
                        draft.guest = vmid
                        draft.kind = candidates.first { $0.vmid == vmid }?.kind ?? .virtualMachine
                    })) {
                        Text("Choose").tag(0)
                        ForEach(candidates) { guest in
                            Text("\(String(guest.vmid)) · \(guest.name)").tag(guest.vmid)
                        }
                    }
                    .accessibilityIdentifier("ha.guest")
                    FieldError(message: errors["sid"])
                } else {
                    LabeledContent("Guest", value: [draft.sid, manager.connection.snapshot?.guests.first { $0.vmid == draft.guest }?.name].compactMap { $0 }.joined(separator: " · "))
                }
                Picker("Requested State", selection: $draft.state) {
                    ForEach(HAResourceDraft.states, id: \.self) { Text(Self.stateTitle($0)).tag($0) }
                }
                .accessibilityIdentifier("ha.state")
            } footer: {
                Text(stateFooter)
            }
            Section {
                Stepper("Max. Restart: \(draft.maxRestart)", value: number($draft.maxRestart), in: 0...10)
                    .accessibilityIdentifier("ha.maxRestart")
                FieldError(message: errors["max_restart"])
                Stepper("Max. Relocate: \(draft.maxRelocate)", value: number($draft.maxRelocate), in: 0...10)
                FieldError(message: errors["max_relocate"])
                Toggle("Failback", isOn: $draft.failback)
                Toggle("Auto-Rebalance", isOn: $draft.autoRebalance)
                LabeledContent("Comment") {
                    TextField("Comment", text: $draft.comment, prompt: Text("None"))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("ha.comment")
                }
            } footer: {
                Text("A failed start is retried on the same node up to Max. Restart times, then on other nodes up to Max. Relocate times. Failback moves the guest back to its preferred node when that node returns; Auto-Rebalance lets the scheduler move it to balance the load.")
            }
            if let resource {
                Section {
                    LabeledContent("State", value: service?.state ?? resource.state)
                    LabeledContent("Node", value: service?.node ?? "–")
                    Button("Move to Another Node…", systemImage: "arrow.left.arrow.right") { moving = true }
                        .disabled(service?.node == nil)
                        .accessibilityIdentifier("ha.move")
                    Button("Remove from HA", systemImage: "trash", role: .destructive) { confirmsRemoval = true }
                        .accessibilityIdentifier("ha.remove")
                } header: {
                    Text("Current")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? "Add to HA" : resource?.sid ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                    .disabled(!isNew && draft.changes(from: original).isEmpty)
                    .accessibilityIdentifier("save")
            }
        }
        .task {
            if manager.resources == nil { await manager.load() }
            // Keeps the current state and node up to date, e.g. while HA moves the guest.
            guard resource != nil else { return }
            await manager.keepRefreshing()
        }
        .sheet(isPresented: $moving) {
            if let resource, let node = service?.node {
                NavigationStack {
                    HAMoveView(manager: manager, sid: resource.sid, currentNode: node)
                }
            }
        }
        .confirmationDialog("Remove from HA?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove(purge: true) } }
            Button("Remove, Keep in Rules") { Task { await remove(purge: false) } }
        } message: {
            Text("The guest keeps running as it is, but no longer moves when its node fails.")
        }
    }

    private var stateFooter: String {
        switch draft.state {
        case "stopped": String(localized: "HA keeps the guest stopped, but moves it to another node when its node fails.")
        case "ignored": String(localized: "HA leaves the guest alone, as if it were not managed, until the state changes.")
        case "disabled": String(localized: "Disabling the resource stops the guest, and HA does not move it.")
        default: String(localized: "HA keeps the guest running and starts it on another node when its node fails.")
        }
    }

    static func stateTitle(_ state: String) -> LocalizedStringKey {
        switch state {
        case "started": "Started"
        case "stopped": "Stopped"
        case "ignored": "Ignored"
        case "disabled": "Disabled"
        default: LocalizedStringKey(state)
        }
    }

    private func number(_ text: Binding<String>) -> Binding<Int> {
        Binding(get: { Int(text.wrappedValue) ?? 1 }, set: { text.wrappedValue = String($0) })
    }

    private func save() async {
        errors = draft.problems
        guard errors.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if let resource {
                try await manager.update(resource.sid, draft.changes(from: original))
            } else {
                try await manager.add(draft)
            }
            dismiss()
        } catch .invalid(let message, let fields) {
            errors = fields
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(purge: Bool) async {
        guard let resource else { return }
        do {
            try await manager.remove(resource.sid, purgeFromRules: purge)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Moves a resource with HA: live (migrate) or by stopping and starting it on the target (relocate).
struct HAMoveView: View {
    let manager: HAManager
    let sid: String
    let currentNode: String
    @State private var target: String
    @State private var relocate = false
    @State private var isMoving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(manager: HAManager, sid: String, currentNode: String) {
        self.manager = manager
        self.sid = sid
        self.currentNode = currentNode
        _target = State(initialValue: manager.connection.snapshot?.nodes.first { $0.isOnline && $0.name != currentNode }?.name ?? "")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Source", value: currentNode)
                Picker("Target", selection: $target) {
                    ForEach(manager.connection.snapshot?.nodes.filter { $0.isOnline && $0.name != currentNode } ?? []) { node in
                        Text(node.name).tag(node.name)
                    }
                }
                .accessibilityIdentifier("ha.move.target")
                Picker("Mode", selection: $relocate) {
                    Text("Migrate").tag(false)
                    Text("Relocate").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(relocate
                    ? "Relocate stops the guest, then HA starts it on the target."
                    : "Migrate moves a running VM live; containers restart on the target. Rules can keep HA from moving it.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Move \(sid)")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isMoving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton(relocate ? "Relocate" : "Migrate", isWorking: isMoving) { Task { await move() } }
                    .disabled(target.isEmpty)
                    .accessibilityIdentifier("ha.move.confirm")
            }
        }
    }

    private func move() async {
        isMoving = true
        defer { isMoving = false }
        do {
            try await manager.move(sid, to: target, relocate: relocate)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The HA of one guest, from its More tab: its HA settings, or adding it.
struct GuestHAView: View {
    let reference: GuestReference
    @State private var manager: HAManager

    init(connection: ServerConnection, reference: GuestReference) {
        self.reference = reference
        _manager = State(initialValue: HAManager(connection: connection))
    }

    var body: some View {
        Group {
            if manager.resources == nil {
                ProgressView()
                    .task { await manager.load() }
            } else if let resource = manager.resource(forGuest: reference.vmid) {
                HAResourceEditor(manager: manager, resource: resource, guest: reference)
                    .id(resource.sid)
            } else {
                HAResourceEditor(manager: manager, resource: nil, guest: reference)
            }
        }
        .navigationTitle("High Availability")
    }
}

/// Node and resource affinity rules (PVE 9).
struct HARulesView: View {
    let manager: HAManager
    @State private var adding: HARule.Kind?
    @State private var removing: HARule?
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(HARule.Kind.allCases) { kind in
                let rules = (manager.rules ?? []).filter { $0.kind == kind }
                Section {
                    if rules.isEmpty {
                        Text("No rules")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rules) { rule in
                        NavigationLink {
                            HARuleEditor(manager: manager, rule: rule, kind: kind)
                        } label: {
                            HARuleRow(rule: rule, names: guestNames)
                        }
                        .accessibilityIdentifier("ha.rule.\(rule.id)")
                        .swipeActions {
                            Button("Remove", systemImage: "trash") { removing = rule }
                                .tint(.red)
                        }
                    }
                } header: {
                    Text(kind == .nodeAffinity ? "Node Affinity" : "Resource Affinity")
                } footer: {
                    Text(kind == .nodeAffinity
                        ? "Which nodes resources prefer or avoid. Strict rules keep them off other nodes, even when that stops them."
                        : "Resources that run on the same node, or on different nodes.")
                }
            }
        }
        .navigationTitle("HA Rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("Node Affinity Rule", systemImage: "mappin") { adding = .nodeAffinity }
                    Button("Resource Affinity Rule", systemImage: "link") { adding = .resourceAffinity }
                }
                .accessibilityIdentifier("ha.rule.add")
            }
        }
        .refreshable { await manager.load() }
        .task { await manager.keepRefreshing() }
        .sheet(item: $adding) { kind in
            NavigationStack {
                HARuleEditor(manager: manager, rule: nil, kind: kind)
            }
        }
        .confirmationDialog("Remove this rule?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { rule in
            Button("Remove", role: .destructive) {
                Task {
                    do {
                        try await manager.remove(rule)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        .alert("HA Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var guestNames: [String: String] {
        Dictionary((manager.connection.snapshot?.guests ?? []).map { (HAResource.sid(for: $0.vmid, kind: $0.kind), $0.name) }) { first, _ in first }
    }
}

struct HARuleRow: View {
    let rule: HARule
    let names: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: !rule.errors.isEmpty ? "exclamationmark.triangle.fill" : rule.isEnabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(!rule.errors.isEmpty ? Color.orange : rule.isEnabled ? Color.green : Color.secondary)
                Text(title)
                    .font(.headline)
            }
            Text(rule.resources.map { names[$0] ?? $0 }.joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let comment = rule.comment {
                Text(comment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch rule.kind {
        case .nodeAffinity:
            let nodes = rule.nodes.map { node in node.priority.map { "\(node.name) (\($0))" } ?? node.name }.joined(separator: ", ")
            let verb = rule.affinity == "negative" ? String(localized: "Avoid") : String(localized: "Prefer")
            return rule.isStrict ? String(localized: "\(verb) \(nodes), strict") : "\(verb) \(nodes)"
        case .resourceAffinity:
            return rule.affinity == "negative" ? String(localized: "Keep separate") : String(localized: "Keep together")
        }
    }
}

/// The web interface's node and resource affinity rule dialogs.
struct HARuleEditor: View {
    let manager: HAManager
    let rule: HARule?
    let kind: HARule.Kind
    @State private var draft: HARuleDraft
    private let original: HARuleDraft
    @State private var errors: [String: String] = [:]
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(manager: HAManager, rule: HARule?, kind: HARule.Kind) {
        self.manager = manager
        self.rule = rule
        self.kind = kind
        let draft = rule.map(HARuleDraft.init) ?? HARuleDraft(kind: kind)
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { rule == nil }
    private var nodes: [String] { manager.connection.snapshot?.nodes.map(\.name).sorted() ?? [] }

    var body: some View {
        Form {
            if let rule, !rule.errors.isEmpty {
                Section("Not Applied") {
                    ForEach(rule.errors.sorted { $0.key < $1.key }, id: \.key) { key, messages in
                        ForEach(messages, id: \.self) { message in
                            Label("\(key): \(message)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section {
                Toggle("Enabled", isOn: $draft.isEnabled)
                Picker("Affinity", selection: $draft.affinity) {
                    if kind == .nodeAffinity {
                        Text("Prefer Nodes").tag("positive")
                        Text("Avoid Nodes").tag("negative")
                    } else {
                        Text("Keep Together").tag("positive")
                        Text("Keep Separate").tag("negative")
                    }
                }
                .accessibilityIdentifier("ha.rule.affinity")
                if kind == .nodeAffinity {
                    Toggle("Strict", isOn: $draft.isStrict)
                }
                LabeledContent("Comment") {
                    TextField("Comment", text: $draft.comment, prompt: Text("None"))
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                if kind == .nodeAffinity {
                    Text(draft.isStrict
                        ? "Strict: the resources run only on the chosen nodes (or never on them), and stop if that is impossible."
                        : "Non-strict: the resources run elsewhere when the chosen nodes are unavailable.")
                }
            }
            Section {
                let resources = manager.resources ?? []
                if resources.isEmpty {
                    Text("Add guests to HA first.")
                        .foregroundStyle(.secondary)
                }
                ForEach(resources) { resource in
                    Button {
                        if draft.resources.contains(resource.sid) { draft.resources.remove(resource.sid) } else { draft.resources.insert(resource.sid) }
                    } label: {
                        HStack {
                            Image(systemName: draft.resources.contains(resource.sid) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(draft.resources.contains(resource.sid) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            Text([resource.sid, manager.connection.snapshot?.guests.first { $0.vmid == resource.vmid }?.name].compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(.primary)
                        }
                    }
                    .accessibilityIdentifier("ha.rule.resource.\(resource.sid)")
                }
                FieldError(message: errors["resources"])
            } header: {
                Text("HA Resources")
            }
            if kind == .nodeAffinity {
                Section {
                    ForEach(nodes, id: \.self) { node in
                        HStack {
                            Toggle(node, isOn: Binding(get: { draft.nodes.keys.contains(node) }, set: { on in
                                if on { draft.nodes[node] = Int?.none } else { draft.nodes[node] = nil }
                            }))
                            .accessibilityIdentifier("ha.rule.node.\(node)")
                        }
                        if draft.nodes.keys.contains(node), draft.affinity == "positive" {
                            Picker("Priority", selection: Binding(get: { draft.nodes[node] ?? nil }, set: { draft.nodes[node] = $0 })) {
                                Text("None").tag(Int?.none)
                                ForEach(1...10, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                            }
                            .padding(.leading, 16)
                        }
                    }
                    FieldError(message: errors["nodes"])
                } header: {
                    Text("Nodes")
                } footer: {
                    Text("With priorities, resources run on the available nodes with the highest one.")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? (kind == .nodeAffinity ? "Node Affinity Rule" : "Resource Affinity Rule") : rule?.id ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .onChange(of: draft.affinity) { _, affinity in
            // Priorities only matter for preferred nodes.
            if affinity == "negative" { for node in draft.nodes.keys { draft.nodes[node] = Int?.none } }
        }
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                    .disabled(!isNew && draft.changes(from: original).isEmpty)
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func save() async {
        errors = draft.problems
        guard errors.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if let rule {
                try await manager.update(rule, draft.changes(from: original))
            } else {
                try await manager.add(draft)
            }
            dismiss()
        } catch .invalid(let message, let fields) {
            errors = fields
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
