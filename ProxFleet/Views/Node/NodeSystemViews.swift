import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Form scaffold for node settings: Save button, saving state, read-only mode without the privilege, and
/// validation errors under their fields. Like `ConfigEditor`, but saving is up to the caller.
struct NodeSettingsForm<Content: View>: View {
    let title: LocalizedStringKey
    let detail: NodeDetail
    var privilege = "Sys.Modify"
    let hasChanges: Bool
    /// Problems the app can see itself, by parameter name. Shown instead of saving.
    var problems: [String: String] = [:]
    let save: () async throws(ConfigUpdateError) -> Void
    @ViewBuilder let content: (_ fieldErrors: [String: String]) -> Content

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    private var isReadOnly: Bool { !detail.can(privilege) }

    var body: some View {
        Form {
            if isReadOnly {
                Section {
                    Label {
                        Text("Read only. Changing this needs the \(detail.privilegeName(privilege)) privilege on \(detail.privilegePath).")
                    } icon: {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            Group {
                content(fieldErrors)
            }
            .disabled(isReadOnly)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            if !isReadOnly {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton("Save", isWorking: isSaving) { Task { await run() } }
                        .disabled(!hasChanges)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    private func run() async {
        guard problems.isEmpty else {
            fieldErrors = problems
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { isSaving = false }
        do {
            try await save()
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Shows `content` once `value` has loaded, and loads the node's system settings (or what `load` loads) meanwhile.
struct NodeSettingLoader<Value, Content: View>: View {
    let detail: NodeDetail
    let value: Value?
    var load: (() async -> String?)?
    @ViewBuilder let content: (Value) -> Content
    @State private var errorMessage: String?

    var body: some View {
        if let value {
            content(value)
        } else if let errorMessage {
            ContentUnavailableView("Cannot Load the Settings", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else {
            ProgressView()
                .task {
                    if let load {
                        errorMessage = await load()
                    } else {
                        errorMessage = await detail.loadSystemSettings()
                    }
                }
        }
    }
}

/// A text field with its label in front, as in the guest editors. Technical values: no autocorrection or capitals.
struct LabeledTextField: View {
    let title: LocalizedStringKey
    var prompt: LocalizedStringKey = ""
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var identifier: String?

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text(prompt))
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(identifier ?? "")
        }
    }
}

// MARK: - DNS

struct NodeDNSEditor: View {
    let detail: NodeDetail
    let original: NodeDNS
    @State private var dns: NodeDNS

    init(detail: NodeDetail, dns: NodeDNS) {
        self.detail = detail
        original = dns
        _dns = State(initialValue: dns)
    }

    var body: some View {
        NodeSettingsForm(title: "DNS", detail: detail, hasChanges: dns != original, problems: problems) { () throws(ConfigUpdateError) in
            try await detail.saveDNS(dns)
        } content: { errors in
            Section {
                LabeledTextField(title: "Domain", prompt: "example.com", text: $dns.searchDomain, identifier: "dns.search")
                FieldError(message: errors["search"])
            } header: {
                Text("Search Domain")
            } footer: {
                Text("Appended to host names that are not fully qualified.")
            }
            Section {
                ForEach(0..<3, id: \.self) { index in
                    LabeledTextField(title: "Server \(index + 1)", prompt: "None", text: $dns.servers[index], keyboard: .numbersAndPunctuation, identifier: "dns.server\(index + 1)")
                    FieldError(message: errors["dns\(index + 1)"])
                }
            } header: {
                Text("DNS Servers")
            } footer: {
                Text("IPv4 or IPv6 addresses, written to /etc/resolv.conf.")
            }
        }
    }

    private var problems: [String: String] {
        dns.searchDomain.trimmingCharacters(in: .whitespaces).isEmpty ? ["search": String(localized: "Enter a search domain.")] : [:]
    }
}

// MARK: - Notes and options

/// Notes of the node, shown in the web interface's node summary.
struct NodeNotesEditor: View {
    let detail: NodeDetail
    let original: String
    @State private var notes: String

    init(detail: NodeDetail, options: NodeOptions) {
        self.detail = detail
        original = options.notes
        _notes = State(initialValue: options.notes)
    }

    var body: some View {
        NodeSettingsForm(title: "Notes", detail: detail, hasChanges: notes != original) { () throws(ConfigUpdateError) in
            var update = GuestConfigUpdate()
            update.set("description", notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes)
            try await detail.saveOptions(update)
        } content: { _ in
            Section {
                TextEditor(text: $notes)
                    .frame(minHeight: 260)
                    .accessibilityIdentifier("node.notes")
            } footer: {
                Text("Markdown is supported in the web interface. Notes are stored in the cluster configuration, so every node shows them.")
            }
        }
    }
}

/// Markdown notes as formatted text; block elements such as headings show as plain lines.
struct NotesText: View {
    let notes: String

    var body: some View {
        if let formatted = try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(formatted)
        } else {
            Text(notes)
        }
    }
}

/// Wake on LAN, the start-at-boot delay and the ballooning target, as in the node's Options panel of the web interface.
struct NodeOptionsEditor: View {
    let detail: NodeDetail
    let original: NodeOptionsDraft
    @State private var draft: NodeOptionsDraft

    init(detail: NodeDetail, options: NodeOptions) {
        self.detail = detail
        original = NodeOptionsDraft(options)
        _draft = State(initialValue: NodeOptionsDraft(options))
    }

    var body: some View {
        NodeSettingsForm(title: "Options", detail: detail, hasChanges: draft != original, problems: draft.problems) { () throws(ConfigUpdateError) in
            try await detail.saveOptions(draft.changes(from: original))
        } content: { errors in
            Section {
                LabeledTextField(title: "MAC Address", prompt: "Not Set", text: $draft.macAddress, keyboard: .asciiCapable, identifier: "options.mac")
                if supports(.wakeOnLANOptions) {
                    LabeledTextField(title: "Interface", prompt: "Default Route", text: $draft.bindInterface, identifier: "options.interface")
                    LabeledTextField(title: "Broadcast Address", prompt: "255.255.255.255", text: $draft.broadcastAddress, keyboard: .numbersAndPunctuation, identifier: "options.broadcast")
                }
                FieldError(message: errors["wakeonlan"])
            } header: {
                Text("Wake on LAN")
            } footer: {
                Text(supports(.wakeOnLANOptions)
                    ? "The MAC address of this node's network card. Another node of the cluster sends the magic packet from the interface given, or from the one carrying the default route."
                    : "The MAC address of this node's network card. Another node of the cluster sends the magic packet.")
            }
            Section {
                LabeledTextField(title: "Start Delay", prompt: "0 s", text: $draft.startDelay, keyboard: .numberPad, identifier: "options.startDelay")
                FieldError(message: errors["startall-onboot-delay"])
            } footer: {
                Text("Seconds to wait after the node booted before starting the guests set to start at boot, up to 300.")
            }
            if supports(.nodeBallooningTarget) {
                Section {
                    LabeledTextField(title: "Ballooning Target", prompt: "80 %", text: $draft.ballooningTarget, keyboard: .numberPad, identifier: "options.ballooning")
                    FieldError(message: errors["ballooning-target"])
                } footer: {
                    Text("The node's memory use, in percent, that ballooning aims for by taking memory back from VMs.")
                }
            }
            if supports(.locations) {
                Section {
                    LabeledTextField(title: "Latitude", prompt: "52.2297", text: $draft.location.latitude, keyboard: .numbersAndPunctuation, identifier: "options.latitude")
                    LabeledTextField(title: "Longitude", prompt: "21.0122", text: $draft.location.longitude, keyboard: .numbersAndPunctuation, identifier: "options.longitude")
                    LabeledTextField(title: "Name", prompt: "None", text: $draft.location.name)
                    FieldError(message: errors["location"])
                } header: {
                    Text("Location")
                } footer: {
                    Text("Where this node is, for the web interface's map. Empty uses the datacenter's location.")
                }
            }
        }
    }

    private func supports(_ feature: PVEFeature) -> Bool { detail.connection.supports(feature) }
}

// MARK: - Hosts

struct NodeHostsEditor: View {
    let detail: NodeDetail
    let original: String
    @State private var text: String

    init(detail: NodeDetail, hosts: NodeHosts) {
        self.detail = detail
        original = hosts.text
        _text = State(initialValue: hosts.text)
    }

    var body: some View {
        NodeSettingsForm(title: "Hosts", detail: detail, hasChanges: text != original) { () throws(ConfigUpdateError) in
            try await detail.saveHosts(text)
        } content: { _ in
            Section {
                TextEditor(text: $text)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 320)
                    .accessibilityIdentifier("hosts.text")
            } footer: {
                Text("The node's /etc/hosts. Each line maps an IP address to host names.")
            }
        }
    }
}

// MARK: - Time

/// The node's clock and a searchable list of time zones; choosing one saves it right away.
struct NodeTimeZoneView: View {
    let detail: NodeDetail
    @State private var search = ""
    @State private var saving: String?
    @State private var errorMessage: String?

    private static let regions = NodeTime.zonesByRegion()

    private var filtered: [(region: String, zones: [String])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Self.regions }
        return Self.regions.compactMap { region in
            let zones = region.zones.filter { $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(query) }
            return zones.isEmpty ? nil : (region: region.region, zones: zones)
        }
    }

    var body: some View {
        List {
            if let time = detail.time, search.isEmpty {
                Section {
                    LabeledContent("Time Zone", value: time.timeZone)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LabeledContent("Node Time", value: nodeTime(time, now: context.date))
                    }
                } footer: {
                    Text("The clock is kept in sync by chrony. Only the time zone can be changed here.")
                }
            }
            ForEach(filtered, id: \.region) { region in
                Section(region.region) {
                    ForEach(region.zones, id: \.self) { zone in
                        Button {
                            Task { await choose(zone) }
                        } label: {
                            HStack {
                                Text(Self.cityName(zone))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if saving == zone {
                                    ProgressView()
                                } else if detail.time?.timeZone == zone {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .fontWeight(.semibold)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(saving != nil || !detail.can("Sys.Modify"))
                        .accessibilityIdentifier("zone.\(zone)")
                        .accessibilityAddTraits(detail.time?.timeZone == zone ? .isSelected : [])
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search Time Zones")
        .navigationTitle("Time Zone")
        .navigationBarTitleDisplayMode(.inline)
        .task { if detail.time == nil { errorMessage = await detail.loadSystemSettings() } }
        .alert("Time Zone Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// `America/Argentina/Buenos_Aires` → `Argentina / Buenos Aires`.
    private static func cityName(_ zone: String) -> String {
        guard zone.contains("/") else { return zone }
        return zone.split(separator: "/").dropFirst().joined(separator: " / ").replacingOccurrences(of: "_", with: " ")
    }

    /// The node's clock, advanced since it was loaded, in the node's time zone.
    private func nodeTime(_ time: NodeTime, now: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .standard)
        style.timeZone = TimeZone(identifier: time.timeZone) ?? .gmt
        return time.clock(at: now).formatted(style)
    }

    private func choose(_ zone: String) async {
        guard zone != detail.time?.timeZone else { return }
        saving = zone
        defer { saving = nil }
        do {
            try await detail.setTimeZone(zone)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Wake on LAN

/// Sends a wake-on-LAN packet to an offline node and tells the user what happened.
struct WakeOnLANButton: View {
    let node: String
    let connection: ServerConnection
    @State private var isSending = false
    @State private var result: WakeOnLANResult?

    var body: some View {
        Button {
            Task { result = await WakeOnLANResult.send(to: node, connection: connection, isSending: $isSending) }
        } label: {
            HStack {
                Label("Wake on LAN", systemImage: "power.circle")
                Spacer()
                if isSending { ProgressView() }
            }
        }
        .disabled(isSending)
        .accessibilityIdentifier("node.wake")
        .wakeOnLANAlert($result)
    }
}

/// The outcome of a wake-on-LAN request, for an alert.
struct WakeOnLANResult: Identifiable {
    let node: String
    let macAddress: String?
    let error: String?

    var id: String { node }

    @MainActor
    static func send(to node: String, connection: ServerConnection, isSending: Binding<Bool>) async -> WakeOnLANResult {
        isSending.wrappedValue = true
        defer { isSending.wrappedValue = false }
        do {
            let mac = try await connection.send(PVE.wakeOnLAN(node))
            return WakeOnLANResult(node: node, macAddress: mac, error: nil)
        } catch {
            return WakeOnLANResult(node: node, macAddress: nil, error: error.localizedDescription)
        }
    }
}

extension View {
    func wakeOnLANAlert(_ result: Binding<WakeOnLANResult?>) -> some View {
        alert(
            result.wrappedValue?.error == nil ? "Wake-Up Sent" : "Wake on LAN Failed",
            isPresented: Binding(get: { result.wrappedValue != nil }, set: { if !$0 { result.wrappedValue = nil } }),
            presenting: result.wrappedValue
        ) { _ in
            Button("OK") {}
        } message: { result in
            if let error = result.error {
                Text(error)
            } else {
                Text("A magic packet went to \(result.macAddress ?? "") for \(result.node). The node shows as online once it has booted.")
            }
        }
    }
}
