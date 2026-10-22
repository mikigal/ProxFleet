import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Adds or edits a firewall rule: a direction with an action, or a security group to apply, plus what it matches.
struct FirewallRuleEditor: View {
    let firewall: Firewall
    let rule: FirewallRule?
    let original: FirewallRuleDraft
    @State private var draft: FirewallRuleDraft
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(firewall: Firewall, rule: FirewallRule?) {
        self.firewall = firewall
        self.rule = rule
        var draft = rule.map(FirewallRuleDraft.init) ?? FirewallRuleDraft()
        // VNets only have forward rules.
        if rule == nil, let first = firewall.scope.directions.first, !firewall.scope.directions.contains(where: { $0.rawValue == draft.type }) {
            draft.type = first.rawValue
        }
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { rule == nil }
    private var isInGroup: Bool {
        if case .group = firewall.scope { return true }
        return false
    }

    private var errors: [String: String] {
        (showsProblems ? draft.problems : [:]).merging(fieldErrors) { _, server in server }
    }

    var body: some View {
        Form {
            if !firewall.canModify {
                Section {
                    Label("Read only. Changes need the \(firewall.scope.modifyPrivilege) privilege on \(firewall.scope.aclPath).", systemImage: "lock.fill")
                        .font(.subheadline)
                }
            }
            if let rule, !rule.errors.isEmpty {
                Section {
                    ForEach(rule.errors.sorted { $0.key < $1.key }, id: \.key) { key, message in
                        Label("\(key): \(message.trimmingCharacters(in: .whitespacesAndNewlines))", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("The firewall skips this rule until the problem is fixed.")
                }
            }
            Group {
                generalSection
                if !draft.isGroup {
                    trafficSection
                    addressSection
                    Section {
                        Picker("Log Level", selection: $draft.logLevel) {
                            ForEach(FirewallRuleDraft.logLevels, id: \.self) { level in
                                Text(level == "nolog" ? String(localized: "No Logging") : level).tag(level)
                            }
                        }
                        FieldError(message: errors["log"])
                    } footer: {
                        if firewall.scope.hasLog || firewall.scope == .datacenter || isInGroup {
                            Text("Matching packets show in the firewall log of the node or guest.")
                        }
                    }
                }
            }
            .disabled(!firewall.canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? "New Rule" : "Rule \(String(rule?.position ?? 0))")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if firewall.canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!isNew && draft.changes(from: original).isEmpty)
                        .accessibilityIdentifier("save")
                }
            }
        }
        .task { await firewall.loadEditorChoices() }
    }

    // MARK: Sections

    private var generalSection: some View {
        Section {
            Toggle("Enabled", isOn: $draft.isEnabled)
                .accessibilityIdentifier("rule.enabled")
            Picker("Type", selection: $draft.type) {
                ForEach(firewall.scope.directions) { direction in
                    Text(Self.title(of: direction)).tag(direction.rawValue)
                }
                if !isInGroup { Text("Group").tag("group") }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("rule.type")
            FieldError(message: errors["type"])
            if draft.isGroup {
                Picker("Security Group", selection: $draft.group) {
                    if draft.group.isEmpty { Text("Choose").tag("") }
                    ForEach(firewall.groups ?? []) { group in
                        Text(group.name).tag(group.name)
                    }
                    if !draft.group.isEmpty, !(firewall.groups ?? []).contains(where: { $0.name == draft.group }) { Text(draft.group).tag(draft.group) }
                }
                .accessibilityIdentifier("rule.group")
            } else {
                Picker("Action", selection: $draft.action) {
                    ForEach(draft.type == "forward" ? FirewallRuleDraft.forwardActions : FirewallRuleDraft.actions, id: \.self) { action in
                        Text(action).tag(action)
                    }
                    if draft.type == "forward", draft.action == "REJECT" { Text("REJECT").tag("REJECT") }
                }
                .accessibilityIdentifier("rule.action")
            }
            FieldError(message: errors["action"])
            LabeledTextField(title: "Interface", prompt: interfacePrompt, text: $draft.interface, identifier: "rule.iface")
            FieldError(message: errors["iface"])
            LabeledContent("Comment") {
                TextField("Comment", text: $draft.comment, prompt: Text("None"))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("rule.comment")
            }
            FieldError(message: errors["comment"])
        } footer: {
            if draft.isGroup {
                Text("Applies the rules of the group here, at the position of this rule.")
            } else if draft.type == "forward" {
                Text("Forward rules only take effect with the nftables firewall, which is set in the node options.")
            } else {
                Text("DROP discards packets silently; REJECT answers that the port is closed.")
            }
        }
    }

    private var interfacePrompt: LocalizedStringKey {
        if case .guest = firewall.scope { return "Any (net0, net1…)" }
        return "Any"
    }

    private var trafficSection: some View {
        Section {
            NavigationLink {
                MacroPicker(selection: $draft.macro, macros: firewall.macros)
            } label: {
                LabeledContent("Macro", value: draft.macro.isEmpty ? String(localized: "None") : draft.macro)
            }
            .accessibilityIdentifier("rule.macro")
            FieldError(message: errors["macro"])
            if !draft.usesMacro {
                HStack {
                    LabeledTextField(title: "Protocol", prompt: "Any", text: $draft.proto, identifier: "rule.proto")
                    Menu {
                        ForEach(FirewallRuleDraft.protocols, id: \.self) { proto in
                            Button(proto) { draft.proto = proto }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .padding(.leading, 4)
                    .accessibilityLabel("Protocols")
                    .accessibilityIdentifier("rule.protocols")
                }
                FieldError(message: errors["proto"])
                if draft.isICMP {
                    HStack {
                        LabeledTextField(title: "ICMP Type", prompt: "Any", text: $draft.icmpType, identifier: "rule.icmp")
                        Menu {
                            ForEach(draft.proto == "icmp" ? FirewallRuleDraft.icmpTypes : FirewallRuleDraft.icmpv6Types, id: \.self) { type in
                                Button(type) { draft.icmpType = type }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .padding(.leading, 4)
                        .accessibilityLabel("ICMP Types")
                    }
                    FieldError(message: errors["icmp-type"])
                } else {
                    LabeledTextField(title: "Destination Port", prompt: "Any", text: $draft.destinationPort, keyboard: .numbersAndPunctuation, identifier: "rule.dport")
                    FieldError(message: errors["dport"])
                    LabeledTextField(title: "Source Port", prompt: "Any", text: $draft.sourcePort, keyboard: .numbersAndPunctuation, identifier: "rule.sport")
                    FieldError(message: errors["sport"])
                }
            }
        } header: {
            Text("Traffic")
        } footer: {
            if draft.usesMacro {
                Text("The macro sets the protocol and ports.")
            } else if !draft.isICMP {
                Text("Ports: numbers or service names, ranges like 1024:2048, several separated by commas. They need tcp or udp.")
            }
        }
    }

    private var addressSection: some View {
        Section {
            AddressField(title: "Source", text: $draft.source, references: firewall.references, identifier: "rule.source")
            FieldError(message: errors["source"])
            AddressField(title: "Destination", text: $draft.destination, references: firewall.references, identifier: "rule.dest")
            FieldError(message: errors["dest"])
        } header: {
            Text("Addresses")
        } footer: {
            Text("An address, a network such as 10.0.0.0/24, a range such as 10.0.0.1-10.0.0.9, an alias, or an IP set as +name. Separate several with commas; empty matches any.")
        }
    }

    static func title(of direction: FirewallRule.Direction) -> LocalizedStringKey {
        switch direction {
        case .in: "In"
        case .out: "Out"
        case .forward: "Forward"
        }
    }

    private func save() async {
        showsProblems = true
        fieldErrors = [:]
        guard draft.problems.isEmpty else {
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if let rule {
                try await firewall.updateRule(rule, draft.changes(from: original))
            } else {
                try await firewall.createRule(draft)
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

/// The standard macros with their descriptions, searchable: a server has close to a hundred.
private struct MacroPicker: View {
    @Binding var selection: String
    let macros: [FirewallMacro]
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var shown: [FirewallMacro] {
        search.isEmpty ? macros : macros.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if search.isEmpty {
                row(name: "", title: String(localized: "None"), description: String(localized: "Set the protocol and ports yourself."))
            }
            ForEach(shown) { macro in
                row(name: macro.name, title: macro.name, description: macro.description)
            }
        }
        .overlay { if macros.isEmpty { ProgressView() } }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle("Macro")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(name: String, title: String, description: String) -> some View {
        Button {
            selection = name
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selection == name {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("macro.\(name.isEmpty ? "none" : name)")
    }
}

/// A source or destination with a menu of the aliases and IP sets the rule may use.
private struct AddressField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let references: [FirewallReference]
    let identifier: String

    var body: some View {
        HStack {
            LabeledTextField(title: title, prompt: "Any", text: $text, keyboard: .numbersAndPunctuation, identifier: identifier)
            if !references.isEmpty {
                Menu {
                    let ipSets = references.filter(\.isIPSet)
                    let aliases = references.filter { !$0.isIPSet }
                    if !ipSets.isEmpty {
                        Section("IP Sets") { buttons(ipSets) }
                    }
                    if !aliases.isEmpty {
                        Section("Aliases") { buttons(aliases) }
                    }
                } label: {
                    Image(systemName: "tag")
                }
                .padding(.leading, 4)
                .accessibilityLabel("Aliases and IP Sets")
                .accessibilityIdentifier("\(identifier).refs")
            }
        }
    }

    @ViewBuilder
    private func buttons(_ references: [FirewallReference]) -> some View {
        ForEach(references) { reference in
            Button {
                text = reference.reference
            } label: {
                Text(reference.reference)
                if let comment = reference.comment ?? (reference.scope == "guest" ? String(localized: "This guest") : nil) {
                    Text(comment)
                }
            }
        }
    }
}
