import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The firewall of the datacenter, a node or a guest: on and off, rules, security groups, aliases, IP sets,
/// options and log, as the web interface's Firewall panels.
struct FirewallView: View {
    @State private var firewall: Firewall
    /// Network devices of a guest; rules only apply to those with the firewall option.
    var interfaces: [GuestNIC] = []
    @State private var confirmsEnabling = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(connection: ServerConnection, scope: FirewallScope, interfaces: [GuestNIC] = []) {
        _firewall = State(initialValue: Firewall(connection: connection, scope: scope))
        self.interfaces = interfaces
    }

    private var scope: FirewallScope { firewall.scope }

    var body: some View {
        List {
            if firewall.options != nil {
                Section {
                    Toggle(isOn: Binding(get: { firewall.isEnabled }, set: { on in
                        if on, scope == .datacenter { confirmsEnabling = true } else { Task { await setEnabled(on) } }
                    })) {
                        Label("Firewall", systemImage: "flame")
                    }
                    .disabled(!firewall.canModify || isWorking)
                    .accessibilityIdentifier("firewall.enabled")
                } footer: {
                    statusFooter
                }
            }
            Section {
                NavigationLink {
                    FirewallRulesView(firewall: firewall)
                } label: {
                    MoreRow(title: "Rules", systemImage: "list.bullet.rectangle", color: .orange, hint: firewall.rules.map { String($0.count) })
                }
                .accessibilityIdentifier("firewall.rules")
                if scope == .datacenter {
                    NavigationLink {
                        SecurityGroupsView(firewall: firewall)
                    } label: {
                        MoreRow(title: "Security Groups", systemImage: "shield.lefthalf.filled", color: .indigo, hint: firewall.groups.map { String($0.count) })
                    }
                    .accessibilityIdentifier("firewall.groups")
                }
                if scope.hasAliasesAndIPSets {
                    NavigationLink {
                        FirewallAliasesView(firewall: firewall)
                    } label: {
                        MoreRow(title: "Aliases", systemImage: "tag", color: .teal, hint: firewall.aliases.map { String($0.count) })
                    }
                    .accessibilityIdentifier("firewall.aliases")
                    NavigationLink {
                        FirewallIPSetsView(firewall: firewall)
                    } label: {
                        MoreRow(title: "IP Sets", systemImage: "square.stack.3d.up", color: .blue, hint: firewall.ipSets.map { String($0.count) })
                    }
                    .accessibilityIdentifier("firewall.ipsets")
                }
                if let options = firewall.options {
                    NavigationLink {
                        FirewallOptionsView(firewall: firewall, options: options)
                    } label: {
                        MoreRow(title: "Options", systemImage: "slider.horizontal.3", color: .gray)
                    }
                    .accessibilityIdentifier("firewall.options")
                }
                if scope.hasLog {
                    NavigationLink {
                        FirewallLogView(firewall: firewall)
                    } label: {
                        MoreRow(title: "Log", systemImage: "doc.text.magnifyingglass", color: .brown)
                    }
                    .accessibilityIdentifier("firewall.log")
                }
            }
            if let error = firewall.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .overlay { if firewall.rules == nil, firewall.loadError == nil { ProgressView() } }
        .navigationTitle("Firewall")
        .refreshable { await firewall.load() }
        .task { await firewall.load() }
        .alert("Turn On the Firewall?", isPresented: $confirmsEnabling) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On") { Task { await setEnabled(true) } }
                .accessibilityIdentifier("firewall.enable.confirm")
        } message: {
            Text("Nodes then drop incoming traffic that no rule allows. The web interface and SSH stay reachable from the local network and the management IP set. If this device connects from another network, add a rule for port 8006 first, or it loses access.")
        }
        .firewallError($errorMessage)
    }

    @ViewBuilder
    private var statusFooter: some View {
        let lockNote = firewall.canModify ? nil : String(localized: "Read only. Changes need the \(scope.modifyPrivilege) privilege on \(scope.aclPath).")
        let unprotected = interfaces.filter { !$0.firewall }.map(\.key)
        let lines: [String] = switch scope {
        case .datacenter:
            [firewall.isEnabled
                ? String(localized: "Nodes filter traffic by the datacenter's rules and their own. Guests filter where their own firewall is on.")
                : String(localized: "No node or guest filters traffic while this is off.")]
        case .node, .guest:
            [
                firewall.isDatacenterEnabled == false ? String(localized: "The datacenter firewall is off, so nothing is filtered here.") : nil,
                scope.nodeName != nil ? String(localized: "The datacenter's rules apply to every node, these to this node only.") : nil,
                scope.isGuest && !firewall.isEnabled ? String(localized: "When on, the guest's traffic is filtered by its rules and policies.") : nil,
                firewall.isEnabled && !unprotected.isEmpty
                    ? String(localized: "Rules only apply to network devices with the firewall option, which \(unprotected.formatted(.list(type: .and))) lacks.")
                    : nil,
            ].compactMap { $0 }
        case .vnet:
            [
                firewall.isDatacenterEnabled == false ? String(localized: "The datacenter firewall is off, so nothing is filtered here.") : nil,
                String(localized: "Filters traffic forwarded through this VNet's bridge, between its guests and to other networks. Needs the nftables firewall on the nodes."),
            ].compactMap { $0 }
        case .group:
            []
        }
        Text((lines + [lockNote].compactMap { $0 }).joined(separator: "\n\n"))
    }

    private func setEnabled(_ on: Bool) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await firewall.setEnabled(on)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// An alert-style error for the firewall screens.
private struct FirewallErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("Firewall Error", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
    }
}

extension View {
    func firewallError(_ message: Binding<String?>) -> some View { modifier(FirewallErrorAlert(message: message)) }
}

struct FirewallBadge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
    }
}

/// Problems the server found in a rule or entry, such as an IP set that no longer exists.
private struct FirewallProblems: View {
    let errors: [String: String]

    var body: some View {
        if !errors.isEmpty {
            Label(errors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: "\n"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private extension FirewallScope {
    var nodeName: String? {
        if case .node(let name) = self { return name }
        return nil
    }

    var isGuest: Bool {
        if case .guest = self { return true }
        return false
    }
}

// MARK: - Rules

struct FirewallRulesView: View {
    let firewall: Firewall
    @State private var creating = false
    @State private var removing: FirewallRule?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if firewall.rules?.isEmpty == true {
                    Text("No rules")
                        .foregroundStyle(.secondary)
                }
                ForEach(firewall.rules ?? []) { rule in
                    NavigationLink {
                        FirewallRuleEditor(firewall: firewall, rule: rule)
                    } label: {
                        FirewallRuleRow(rule: rule)
                    }
                    .accessibilityIdentifier("rule.\(rule.position)")
                    .swipeActions {
                        if firewall.canModify {
                            // Not `role: .destructive`: a full swipe would hide the row, but this only asks first.
                            Button("Remove", systemImage: "trash") { removing = rule }
                                .tint(.red)
                            Button(rule.isEnabled ? "Disable" : "Enable", systemImage: rule.isEnabled ? "pause.circle" : "checkmark.circle") {
                                Task { await setEnabled(rule, !rule.isEnabled) }
                            }
                            .tint(rule.isEnabled ? .gray : .green)
                        }
                    }
                    .contextMenu {
                        if firewall.canModify {
                            Button(rule.isEnabled ? "Disable" : "Enable", systemImage: rule.isEnabled ? "pause.circle" : "checkmark.circle") {
                                Task { await setEnabled(rule, !rule.isEnabled) }
                            }
                            Button("Remove", systemImage: "trash", role: .destructive) { removing = rule }
                        }
                    }
                }
                .onMove(perform: firewall.canModify ? { from, to in
                    guard let position = from.first else { return }
                    Task { await move(position, to: to) }
                } : nil)
            } footer: {
                if case .group = firewall.scope {
                    Text("The rules apply wherever a rule uses this group. They are checked from the top.")
                } else {
                    Text("Rules are checked from the top; the first one that matches decides. Traffic no rule matches follows the policies in Options.")
                }
            }
        }
        .overlay { if firewall.rules == nil { ProgressView() } }
        .navigationTitle(navigationTitle)
        .toolbar {
            if firewall.canModify, (firewall.rules?.count ?? 0) > 1 {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!firewall.canModify)
                    .accessibilityIdentifier("rule.add")
            }
        }
        .refreshable { await firewall.load() }
        .task { if firewall.rules == nil { await firewall.load() } }
        .sheet(isPresented: $creating) {
            NavigationStack {
                FirewallRuleEditor(firewall: firewall, rule: nil)
            }
        }
        .confirmationDialog("Remove this rule?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { rule in
            Button("Remove", role: .destructive) { Task { await remove(rule) } }
        } message: { rule in
            Text(FirewallRuleRow.title(of: rule))
        }
        .firewallError($errorMessage)
    }

    private var navigationTitle: String {
        if case .group(let name) = firewall.scope { return name }
        return String(localized: "Rules")
    }

    private func move(_ position: Int, to offset: Int) async {
        do {
            try await firewall.moveRule(from: position, to: offset)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setEnabled(_ rule: FirewallRule, _ on: Bool) async {
        do {
            try await firewall.setEnabled(rule, on)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ rule: FirewallRule) async {
        do {
            try await firewall.deleteRule(rule)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct FirewallRuleRow: View {
    let rule: FirewallRule

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(rule.isEnabled ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.title(of: rule))
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    FirewallBadge(text: rule.isGroup ? String(localized: "Group") : rule.action, color: rule.isEnabled ? color : .secondary)
                    if !rule.isEnabled { FirewallBadge(text: String(localized: "Off")) }
                }
                if !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let comment = rule.comment {
                    Text(comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                FirewallProblems(errors: rule.errors)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The macro, protocol and port, or the security group a rule applies.
    static func title(of rule: FirewallRule) -> String {
        if rule.isGroup { return rule.action }
        if let macro = rule.macro { return macro }
        if let proto = rule.proto {
            if let port = rule.destinationPort { return "\(proto.uppercased()) \(port)" }
            if let type = rule.icmpType { return "\(proto.uppercased()) \(type)" }
            return proto.uppercased()
        }
        return String(localized: "All Traffic")
    }

    private var details: String {
        var parts: [String] = []
        switch rule.type {
        case "in": parts.append(String(localized: "In"))
        case "out": parts.append(String(localized: "Out"))
        case "forward": parts.append(String(localized: "Forward"))
        default: break
        }
        if !rule.isGroup || rule.source != nil || rule.destination != nil {
            let any = String(localized: "any")
            parts.append("\(rule.source ?? any) → \(rule.destination ?? any)")
        }
        if let port = rule.sourcePort { parts.append(String(localized: "from port \(port)")) }
        if let interface = rule.interface { parts.append(interface) }
        if let level = rule.logLevel { parts.append(String(localized: "log \(level)")) }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        switch rule.type {
        case "in": "arrow.down.left.circle"
        case "out": "arrow.up.right.circle"
        case "forward": "arrow.left.arrow.right.circle"
        default: "shield.lefthalf.filled"
        }
    }

    private var color: Color {
        switch rule.action {
        case "ACCEPT": .green
        case "DROP": .red
        case "REJECT": .orange
        default: .indigo
        }
    }
}

// MARK: - Options

/// The options of a scope, built from `FirewallOptionSpec`: flags, policies, log levels and numbers.
private struct FirewallOptionsView: View {
    let firewall: Firewall
    let original: FirewallOptionsDraft
    @State private var draft: FirewallOptionsDraft
    @State private var isSaving = false
    @State private var confirmsEnabling = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(firewall: Firewall, options: FirewallOptions) {
        self.firewall = firewall
        let draft = FirewallOptionsDraft(options, scope: firewall.scope)
        original = draft
        _draft = State(initialValue: draft)
    }

    private var errors: [String: String] { draft.problems.merging(fieldErrors) { _, server in server } }

    /// Groups the options like the sections of the node options in the web interface's documentation.
    private var sections: [(title: LocalizedStringKey, specs: [FirewallOptionSpec])] {
        func section(_ key: String) -> Int {
            if key.hasPrefix("nf_conntrack") || key == "log_nf_conntrack" { return 2 }
            if key.hasPrefix("protection_synflood") { return 3 }
            if key.hasPrefix("log") || key.hasSuffix("log_level") { return 1 }
            return 0
        }
        let titles: [LocalizedStringKey] = ["General", "Logging", "Connection Tracking", "SYN Flood Protection"]
        return titles.indices.compactMap { index in
            let specs = draft.specs.filter { section($0.key) == index }
            return specs.isEmpty ? nil : (titles[index], specs)
        }
    }

    var body: some View {
        Form {
            if !firewall.canModify {
                Section {
                    Label("Read only. Changes need the \(firewall.scope.modifyPrivilege) privilege on \(firewall.scope.aclPath).", systemImage: "lock.fill")
                        .font(.subheadline)
                }
            }
            ForEach(sections, id: \.specs.first?.key) { section in
                Section(section.title) {
                    ForEach(section.specs) { spec in
                        row(spec)
                    }
                }
            }
            .disabled(!firewall.canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Options")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            if firewall.canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton("Save", isWorking: isSaving) {
                        if firewall.scope == .datacenter, draft.flag("enable"), !original.flag("enable") {
                            confirmsEnabling = true
                        } else {
                            Task { await save() }
                        }
                    }
                    .disabled(draft.changes(from: original).isEmpty)
                    .accessibilityIdentifier("save")
                }
            }
        }
        .alert("Turn On the Firewall?", isPresented: $confirmsEnabling) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On") { Task { await save() } }
        } message: {
            Text("Nodes then drop incoming traffic that no rule allows. The web interface and SSH stay reachable from the local network and the management IP set. If this device connects from another network, add a rule for port 8006 first, or it loses access.")
        }
    }

    @ViewBuilder
    private func row(_ spec: FirewallOptionSpec) -> some View {
        switch spec.kind {
        case .flag:
            Toggle(spec.title, isOn: Binding(get: { draft.flag(spec.key) }, set: { draft.setFlag(spec.key, $0) }))
                .accessibilityIdentifier("option.\(spec.key)")
        case .choice(let values, _):
            Picker(spec.title, selection: Binding(get: { draft.choice(spec.key) }, set: { draft.values[spec.key] = $0 })) {
                ForEach(values, id: \.self) { value in
                    Text(value == "nolog" ? String(localized: "No Logging") : value).tag(value)
                }
                if !values.contains(draft.choice(spec.key)) { Text(draft.choice(spec.key)).tag(draft.choice(spec.key)) }
            }
            .accessibilityIdentifier("option.\(spec.key)")
        case .number(let defaultValue, _):
            LabeledTextField(title: LocalizedStringKey(spec.title), prompt: LocalizedStringKey(String(defaultValue)),
                             text: Binding(get: { draft.values[spec.key] ?? "" }, set: { draft.values[spec.key] = $0.isEmpty ? nil : $0 }),
                             keyboard: .numberPad, identifier: "option.\(spec.key)")
            FieldError(message: errors[spec.key])
        case .set(let members):
            NavigationLink {
                List(members, id: \.self) { member in
                    Toggle(member, isOn: Binding(get: { draft.members(spec.key).contains(member) }, set: { on in
                        var current = draft.members(spec.key)
                        if on { current.insert(member) } else { current.remove(member) }
                        draft.setMembers(spec.key, current)
                    }))
                }
                .navigationTitle(spec.title)
                .disabled(!firewall.canModify)
            } label: {
                LabeledContent(spec.title, value: draft.members(spec.key).isEmpty ? String(localized: "None") : draft.members(spec.key).sorted().joined(separator: ", "))
            }
        case .rateLimit:
            Toggle(spec.title, isOn: Binding(get: { draft.rateLimit.isEnabled }, set: { draft.rateLimit.isEnabled = $0 }))
            if draft.rateLimit.isEnabled {
                LabeledTextField(title: "Rate", prompt: "1/second", text: Binding(get: { draft.rateLimit.rate }, set: { draft.rateLimit.rate = $0 }), identifier: "option.rate")
                NumberField(title: "Burst", value: Binding(get: { draft.rateLimit.burst }, set: { draft.rateLimit.burst = $0 }), range: 0...100_000)
            }
            FieldError(message: errors[spec.key])
        }
        if let footer = spec.footer {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func save() async {
        guard draft.problems.isEmpty else {
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { isSaving = false }
        do {
            try await firewall.saveOptions(draft.changes(from: original))
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Aliases

private struct FirewallAliasesView: View {
    let firewall: Firewall
    @State private var editing: FirewallAlias?
    @State private var creating = false
    @State private var removing: FirewallAlias?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(firewall.aliases ?? []) { alias in
                    Button {
                        editing = alias
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alias.name).font(.body.weight(.medium))
                            Text([alias.cidr, alias.comment].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("alias.\(alias.name)")
                    .swipeActions {
                        if firewall.canModify {
                            Button("Remove", systemImage: "trash") { removing = alias }
                                .tint(.red)
                        }
                    }
                }
            } footer: {
                if firewall.aliases?.isEmpty == false {
                    Text("Rules and IP sets use an alias by its name. Renaming one does not update them.")
                }
            }
        }
        .overlay {
            if firewall.aliases == nil {
                ProgressView()
            } else if firewall.aliases?.isEmpty == true {
                ContentUnavailableView("No Aliases", systemImage: "tag", description: Text("An alias names an address or network, so rules can use the name."))
            }
        }
        .navigationTitle("Aliases")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!firewall.canModify)
                    .accessibilityIdentifier("alias.add")
            }
        }
        .refreshable { await firewall.load() }
        .sheet(isPresented: $creating) {
            NavigationStack { FirewallAliasEditor(firewall: firewall, alias: nil) }
        }
        .sheet(item: $editing) { alias in
            NavigationStack { FirewallAliasEditor(firewall: firewall, alias: alias) }
        }
        .confirmationDialog("Remove the alias \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { alias in
            Button("Remove", role: .destructive) { Task { await remove(alias) } }
        } message: { _ in
            Text("Rules and IP sets that use it stop matching it.")
        }
        .firewallError($errorMessage)
    }

    private func remove(_ alias: FirewallAlias) async {
        do {
            try await firewall.deleteAlias(alias)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FirewallAliasEditor: View {
    let firewall: Firewall
    let alias: FirewallAlias?
    @State private var name: String
    @State private var cidr: String
    @State private var comment: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(firewall: Firewall, alias: FirewallAlias?) {
        self.firewall = firewall
        self.alias = alias
        _name = State(initialValue: alias?.name ?? "")
        _cidr = State(initialValue: alias?.cidr ?? "")
        _comment = State(initialValue: alias?.comment ?? "")
    }

    var body: some View {
        Form {
            Section {
                LabeledTextField(title: "Name", prompt: "lan", text: $name, identifier: "alias.name")
                FieldError(message: fieldErrors["name"] ?? fieldErrors["rename"])
                LabeledTextField(title: "Address", prompt: "192.168.1.0/24", text: $cidr, keyboard: .numbersAndPunctuation, identifier: "alias.cidr")
                FieldError(message: fieldErrors["cidr"])
                LabeledContent("Comment") {
                    TextField("Comment", text: $comment, prompt: Text("None"))
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("An IPv4 or IPv6 address, or a network in CIDR notation.")
            }
            .disabled(!firewall.canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(alias == nil ? "New Alias" : alias?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            if firewall.canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(alias == nil ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(trimmed(name).isEmpty || trimmed(cidr).isEmpty)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }

    private func save() async {
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { isSaving = false }
        do {
            if let alias {
                try await firewall.updateAlias(alias, name: trimmed(name), cidr: trimmed(cidr), comment: trimmed(comment))
            } else {
                try await firewall.createAlias(name: trimmed(name), cidr: trimmed(cidr), comment: trimmed(comment))
            }
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - IP sets

private struct FirewallIPSetsView: View {
    let firewall: Firewall
    @State private var creating = false
    @State private var removing: FirewallIPSet?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(firewall.ipSets ?? []) { set in
                    NavigationLink {
                        FirewallIPSetView(firewall: firewall, name: set.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(set.name).font(.body.weight(.medium))
                            if let details = [set.comment, set.specialPurpose].compactMap({ $0 }).first {
                                Text(details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("ipset.\(set.name)")
                    .swipeActions {
                        if firewall.canModify {
                            Button("Remove", systemImage: "trash") { removing = set }
                                .tint(.red)
                        }
                    }
                }
            } footer: {
                if firewall.scope == .datacenter {
                    Text("Rules use an IP set as +name. The firewall itself uses the sets named management (hosts allowed to reach the web interface and SSH) and blacklist (always dropped).")
                } else {
                    Text("Rules use an IP set as +name. Sets named ipfilter-net0 and so on list the addresses the guest may use on that device when IP Filter is on.")
                }
            }
        }
        .overlay {
            if firewall.ipSets == nil {
                ProgressView()
            } else if firewall.ipSets?.isEmpty == true {
                ContentUnavailableView("No IP Sets", systemImage: "square.stack.3d.up", description: Text("An IP set groups addresses, networks and aliases for rules."))
            }
        }
        .navigationTitle("IP Sets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!firewall.canModify)
                    .accessibilityIdentifier("ipset.add")
            }
        }
        .refreshable { await firewall.load() }
        .sheet(isPresented: $creating) {
            NavigationStack { FirewallNameEditor(kind: .ipSet, firewall: firewall, name: nil, comment: nil) }
        }
        .confirmationDialog("Remove the IP set \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { set in
            Button("Remove", role: .destructive) { Task { await remove(set) } }
        } message: { _ in
            Text("Its entries are removed too. Rules that use it stop matching.")
        }
        .firewallError($errorMessage)
    }

    private func remove(_ set: FirewallIPSet) async {
        do {
            try await firewall.deleteIPSet(set)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FirewallIPSetView: View {
    let firewall: Firewall
    @State var name: String
    @State private var adding = false
    @State private var editing: FirewallIPSetEntry?
    @State private var renaming = false
    @State private var loadError: String?
    @State private var errorMessage: String?

    private var set: FirewallIPSet? { firewall.ipSets?.first { $0.name == name } }
    private var entries: [FirewallIPSetEntry]? { firewall.ipSetEntries[name] }

    var body: some View {
        List {
            if let purpose = set?.specialPurpose {
                Section {
                    Label(purpose, systemImage: "info.circle")
                        .font(.subheadline)
                }
            }
            Section {
                ForEach(entries ?? []) { entry in
                    Button {
                        editing = entry
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.cidr).font(.body.monospaced())
                                if entry.isExcluded { FirewallBadge(text: String(localized: "Excluded"), color: .orange) }
                            }
                            if let comment = entry.comment {
                                Text(comment)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            FirewallProblems(errors: entry.errors)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("entry.\(entry.cidr)")
                    .swipeActions {
                        if firewall.canModify {
                            Button("Remove", systemImage: "trash", role: .destructive) { Task { await remove(entry) } }
                        }
                    }
                }
            } footer: {
                Text("Excluded entries are left out, e.g. one address of a network that is in the set.")
            }
        }
        .overlay {
            if let loadError, entries == nil {
                ContentUnavailableView("Cannot Load the IP Set", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if entries == nil {
                ProgressView()
            } else if entries?.isEmpty == true {
                ContentUnavailableView("Empty", systemImage: "square.stack.3d.up", description: Text("Add addresses, networks or aliases."))
            }
        }
        .navigationTitle(name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { adding = true }
                    .disabled(!firewall.canModify)
                    .accessibilityIdentifier("entry.add")
            }
            if firewall.canModify, set != nil {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Rename", systemImage: "pencil") { renaming = true }
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $adding) {
            NavigationStack { FirewallIPSetEntryEditor(firewall: firewall, set: name, entry: nil) }
        }
        .sheet(item: $editing) { entry in
            NavigationStack { FirewallIPSetEntryEditor(firewall: firewall, set: name, entry: entry) }
        }
        .sheet(isPresented: $renaming) {
            NavigationStack { FirewallNameEditor(kind: .ipSet, firewall: firewall, name: name, comment: set?.comment) { name = $0 } }
        }
        .firewallError($errorMessage)
    }

    private func load() async {
        do {
            try await firewall.loadEntries(of: name)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func remove(_ entry: FirewallIPSetEntry) async {
        do {
            try await firewall.deleteEntry(entry, from: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FirewallIPSetEntryEditor: View {
    let firewall: Firewall
    let set: String
    let entry: FirewallIPSetEntry?
    @State private var cidr: String
    @State private var comment: String
    @State private var isExcluded: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(firewall: Firewall, set: String, entry: FirewallIPSetEntry?) {
        self.firewall = firewall
        self.set = set
        self.entry = entry
        _cidr = State(initialValue: entry?.cidr ?? "")
        _comment = State(initialValue: entry?.comment ?? "")
        _isExcluded = State(initialValue: entry?.isExcluded ?? false)
    }

    private var aliases: [String] {
        firewall.references.filter { !$0.isIPSet }.map(\.reference)
    }

    var body: some View {
        Form {
            Section {
                if entry == nil {
                    HStack {
                        TextField("Address", text: $cidr, prompt: Text("10.0.0.0/24"))
                            .font(.body.monospaced())
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("entry.cidr")
                        if !aliases.isEmpty {
                            Menu {
                                ForEach(aliases, id: \.self) { alias in Button(alias) { cidr = alias } }
                            } label: {
                                Image(systemName: "tag")
                            }
                            .accessibilityLabel("Aliases")
                        }
                    }
                } else {
                    LabeledContent("Address", value: cidr)
                }
                FieldError(message: fieldErrors["cidr"])
                LabeledContent("Comment") {
                    TextField("Comment", text: $comment, prompt: Text("None"))
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Exclude", isOn: $isExcluded)
            } footer: {
                Text("An address, a network in CIDR notation, or an alias.")
            }
            .disabled(!firewall.canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(entry == nil ? "Add to \(set)" : cidr)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            if firewall.canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(entry == nil ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(cidr.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("save")
                }
            }
        }
        .task { if firewall.references.isEmpty { await firewall.loadEditorChoices() } }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { isSaving = false }
        let comment = comment.trimmingCharacters(in: .whitespaces)
        do {
            if let entry {
                try await firewall.updateEntry(entry, in: set, comment: comment, excluded: isExcluded)
            } else {
                try await firewall.addEntry(to: set, cidr: cidr.trimmingCharacters(in: .whitespaces), comment: comment, excluded: isExcluded)
            }
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Name and comment of an IP set or security group, for creating and renaming.
private struct FirewallNameEditor: View {
    enum Kind { case ipSet, group }

    let kind: Kind
    let firewall: Firewall
    let originalName: String?
    /// Called with the saved name, which differs after renaming.
    var onSaved: ((String) -> Void)?
    @State private var name: String
    @State private var comment: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(kind: Kind, firewall: Firewall, name: String?, comment: String?, onSaved: ((String) -> Void)? = nil) {
        self.kind = kind
        self.firewall = firewall
        self.onSaved = onSaved
        originalName = name
        _name = State(initialValue: name ?? "")
        _comment = State(initialValue: comment ?? "")
    }

    private var title: LocalizedStringKey {
        switch (kind, originalName) {
        case (.ipSet, nil): "New IP Set"
        case (.group, nil): "New Security Group"
        case (.ipSet, _): "IP Set"
        case (.group, _): "Security Group"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledTextField(title: "Name", prompt: kind == .ipSet ? "management" : "webserver", text: $name, identifier: "name")
                FieldError(message: fieldErrors["name"] ?? fieldErrors["group"] ?? fieldErrors["rename"])
                LabeledContent("Comment") {
                    TextField("Comment", text: $comment, prompt: Text("None"))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("comment")
                }
            } footer: {
                switch kind {
                case .ipSet where originalName != nil:
                    Text("Renaming does not update rules that use the IP set.")
                case .ipSet:
                    Text("Letters, digits, - and _, starting with a letter.")
                case .group:
                    Text("At most 18 letters, digits, - and _, starting with a letter. Renaming updates the rules that use the group.")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton(originalName == nil ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { isSaving = false }
        let name = name.trimmingCharacters(in: .whitespaces)
        let comment = comment.trimmingCharacters(in: .whitespaces)
        do {
            switch kind {
            case .ipSet:
                try await firewall.saveIPSet(name: name, comment: comment, renaming: originalName.flatMap { old in firewall.ipSets?.first { $0.name == old } })
            case .group:
                try await firewall.saveGroup(name: name, comment: comment, renaming: originalName.flatMap { old in firewall.groups?.first { $0.name == old } })
            }
            onSaved?(name)
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Security groups

private struct SecurityGroupsView: View {
    let firewall: Firewall
    @State private var creating = false
    @State private var removing: FirewallGroup?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(firewall.groups ?? []) { group in
                    NavigationLink {
                        SecurityGroupView(datacenter: firewall, name: group.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).font(.body.weight(.medium))
                            if let comment = group.comment {
                                Text(comment)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("group.\(group.name)")
                    .swipeActions {
                        if firewall.canModify {
                            Button("Remove", systemImage: "trash") { removing = group }
                                .tint(.red)
                        }
                    }
                }
            } footer: {
                Text("A security group is a set of rules that the datacenter, nodes and guests apply with a rule of type Group.")
            }
        }
        .overlay {
            if firewall.groups == nil {
                ProgressView()
            } else if firewall.groups?.isEmpty == true {
                ContentUnavailableView("No Security Groups", systemImage: "shield.lefthalf.filled", description: Text("Groups let several guests share the same rules."))
            }
        }
        .navigationTitle("Security Groups")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!firewall.canModify)
                    .accessibilityIdentifier("group.add")
            }
        }
        .refreshable { await firewall.load() }
        .sheet(isPresented: $creating) {
            NavigationStack { FirewallNameEditor(kind: .group, firewall: firewall, name: nil, comment: nil) }
        }
        .confirmationDialog("Remove the group \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { group in
            Button("Remove", role: .destructive) { Task { await remove(group) } }
        } message: { _ in
            Text("Only a group without rules can be removed.")
        }
        .firewallError($errorMessage)
    }

    private func remove(_ group: FirewallGroup) async {
        do {
            try await firewall.deleteGroup(group)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The rules of one security group, with renaming.
private struct SecurityGroupView: View {
    let datacenter: Firewall
    @State private var name: String
    @State private var rules: Firewall
    @State private var renaming = false

    init(datacenter: Firewall, name: String) {
        self.datacenter = datacenter
        _name = State(initialValue: name)
        _rules = State(initialValue: datacenter.group(name))
    }

    var body: some View {
        FirewallRulesView(firewall: rules)
            .toolbar {
                if datacenter.canModify {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Rename", systemImage: "pencil") { renaming = true }
                    }
                }
            }
            .sheet(isPresented: $renaming) {
                NavigationStack {
                    FirewallNameEditor(kind: .group, firewall: datacenter, name: name, comment: datacenter.groups?.first { $0.name == name }?.comment) { saved in
                        // A renamed group lives at a new path.
                        guard saved != name else { return }
                        name = saved
                        rules = datacenter.group(saved)
                    }
                }
            }
    }
}

// MARK: - Log

private struct FirewallLogView: View {
    let firewall: Firewall
    @State private var lines: [FirewallLog.Line]?
    @State private var search = ""
    @State private var loadError: String?

    private var shown: [FirewallLog.Line] {
        let newest = (lines ?? []).reversed()
        return search.isEmpty ? Array(newest) : newest.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(shown) { line in
            Text(line.text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .listStyle(.plain)
        .overlay {
            if let loadError, lines == nil {
                ContentUnavailableView("Cannot Load the Log", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if lines == nil {
                ProgressView()
            } else if lines?.isEmpty == true {
                ContentUnavailableView("No Entries", systemImage: "doc.text", description: Text("Rules and policies log here when they have a log level."))
            }
        }
        .searchable(text: $search)
        .navigationTitle("Firewall Log")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            lines = try await firewall.loadLog()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
