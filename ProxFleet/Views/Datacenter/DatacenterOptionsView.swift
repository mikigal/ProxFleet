import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The datacenter options (`datacenter.cfg`), loaded, then edited as one form.
struct DatacenterOptionsView: View {
    @State private var settings: DatacenterSettings

    init(connection: ServerConnection) {
        _settings = State(initialValue: DatacenterSettings(connection: connection))
    }

    var body: some View {
        Group {
            if let options = settings.options {
                DatacenterOptionsForm(settings: settings, original: DatacenterOptionsDraft(options))
                    .id(options)
            } else if let error = settings.loadError {
                ContentUnavailableView("Cannot Load the Options", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Options")
        .navigationBarTitleDisplayMode(.inline)
        .task { await settings.loadOptions() }
    }
}

private struct DatacenterOptionsForm: View {
    let settings: DatacenterSettings
    let original: DatacenterOptionsDraft
    @State private var draft: DatacenterOptionsDraft
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @State private var saved = false

    init(settings: DatacenterSettings, original: DatacenterOptionsDraft) {
        self.settings = settings
        self.original = original
        _draft = State(initialValue: original)
    }

    private var errors: [String: String] {
        (showsProblems ? draft.problems : [:]).merging(fieldErrors) { _, server in server }
    }

    private var hasChanges: Bool { !draft.changes(from: original).isEmpty }

    private func supports(_ feature: PVEFeature) -> Bool { settings.connection.supports(feature) }

    var body: some View {
        Form {
            if !settings.canModifyOptions {
                Section {
                    Label("Read only. Changing options needs the Sys.Modify privilege on /.", systemImage: "lock.fill")
                        .font(.subheadline)
                }
            }
            Group {
                consoleSection
                guestsSection
                networkSection
                bandwidthSection
                tagsSection
                haSection
                twoFactorSection
                if supports(.locations) {
                    locationSection
                }
                otherSection
            }
            .disabled(!settings.canModifyOptions)
            ErrorSection(message: errorMessage)
        }
        .disabled(isSaving)
        .toolbar {
            if settings.canModifyOptions {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton("Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!hasChanges)
                        .accessibilityIdentifier("save")
                }
            }
        }
        .sensoryFeedback(.success, trigger: saved)
    }

    private var consoleSection: some View {
        Section {
            Picker("Keyboard Layout", selection: $draft.keyboard) {
                Text("Default").tag("")
                ForEach(DatacenterOptionsDraft.keyboards, id: \.self) { Text(Self.keyboardName($0)).tag($0) }
            }
            .accessibilityIdentifier("options.keyboard")
            Picker("Console Viewer", selection: $draft.console) {
                Text("Default").tag("")
                Text("noVNC").tag("html5")
                Text("xterm.js").tag("xtermjs")
                Text("SPICE (remote-viewer)").tag("vv")
            }
            Picker("Web Interface Language", selection: $draft.language) {
                Text("Default").tag("")
                ForEach(DatacenterOptionsDraft.languages, id: \.self) { Text(Self.languageName($0)).tag($0) }
            }
        } header: {
            Text("Console")
        } footer: {
            Text("The keyboard layout is the one QEMU assumes for VM consoles in the web interface. Viewer and language apply to the web interface.")
        }
    }

    private var guestsSection: some View {
        Section {
            LabeledTextField(title: "Lowest Free ID", prompt: "100", text: $draft.nextIDLower, keyboard: .numberPad, identifier: "options.nextIDLower")
            LabeledTextField(title: "Highest Free ID", prompt: "999999", text: $draft.nextIDUpper, keyboard: .numberPad)
            FieldError(message: errors["next-id"])
            LabeledTextField(title: "MAC Prefix", prompt: "BC:24:11", text: $draft.macPrefix, identifier: "options.macPrefix")
            FieldError(message: errors["mac_prefix"])
        } header: {
            Text("New Guests")
        } footer: {
            Text("New VMs and containers get the lowest free ID in this range, and network cards a MAC address with this prefix.")
        }
    }

    private var networkSection: some View {
        Section {
            LabeledTextField(title: "Email From", prompt: "root@hostname", text: $draft.emailFrom, keyboard: .emailAddress, identifier: "options.emailFrom")
            FieldError(message: errors["email_from"])
            LabeledTextField(title: "HTTP Proxy", prompt: "None", text: $draft.httpProxy, keyboard: .URL)
            FieldError(message: errors["http_proxy"])
            Picker("Migration", selection: $draft.migrationType) {
                Text("Default (Secure)").tag("")
                Text("Secure").tag("secure")
                Text("Insecure").tag("insecure")
            }
            LabeledTextField(title: "Migration Network", prompt: "10.0.0.0/24", text: $draft.migrationNetwork, keyboard: .numbersAndPunctuation)
            // Replication used the migration settings before PVE 9.
            if supports(.replicationOptions) {
                Picker("Replication", selection: $draft.replicationType) {
                    Text("Default (Secure)").tag("")
                    Text("Secure").tag("secure")
                    Text("Insecure").tag("insecure")
                }
                LabeledTextField(title: "Replication Network", prompt: "10.0.0.0/24", text: $draft.replicationNetwork, keyboard: .numbersAndPunctuation)
            }
        } header: {
            Text("Network")
        } footer: {
            Text(supports(.replicationOptions)
                ? "The proxy is used for downloads such as updates and templates. Insecure migration and replication skip the SSH tunnel; use them only on a private network."
                : "The proxy is used for downloads such as updates and templates. Insecure migration skips the SSH tunnel; use it only on a private network. Replication uses the migration settings.")
        }
    }

    private var bandwidthSection: some View {
        Section {
            ForEach(DatacenterOptionsDraft.bandwidthOperations, id: \.self) { operation in
                LabeledContent(Self.bandwidthTitle(operation)) {
                    HStack {
                        TextField("Unlimited", text: Binding(get: { draft.bandwidthLimits[operation] ?? "" }, set: { draft.bandwidthLimits[operation] = $0 }))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text(verbatim: "KiB/s").foregroundStyle(.secondary)
                    }
                }
            }
            FieldError(message: errors["bwlimit"])
        } header: {
            Text("Bandwidth Limits")
        } footer: {
            Text("Default applies to every operation without its own limit. 1 MiB/s is 1024 KiB/s.")
        }
    }

    private var tagsSection: some View {
        Section {
            Picker("Shape", selection: $draft.tagShape) {
                Text("Default (Circle)").tag("")
                Text("Full").tag("full")
                Text("Circle").tag("circle")
                Text("Dense").tag("dense")
                Text("None").tag("none")
            }
            Picker("Order", selection: $draft.tagOrdering) {
                Text("Default (Alphabetical)").tag("")
                Text("Alphabetical").tag("alphabetical")
                Text("As Configured").tag("config")
            }
            Toggle("Case-Sensitive", isOn: $draft.tagsCaseSensitive)
            Picker("Users May Set", selection: $draft.userTagAccess) {
                Text("Default (Any Tag)").tag("")
                Text("Any Tag").tag("free")
                Text("Existing Tags").tag("existing")
                Text("Listed Tags").tag("list")
                Text("No Tags").tag("none")
            }
            if draft.userTagAccess == "list" || draft.userTagAccess == "existing" {
                NavigationLink {
                    Form { TagsEditor(tags: $draft.userTagList) }
                        .navigationTitle("Allowed Tags")
                } label: {
                    LabeledContent("Allowed Tags", value: draft.userTagList.isEmpty ? String(localized: "None") : draft.userTagList.joined(separator: ", "))
                }
            }
            NavigationLink {
                Form {
                    Section {
                        TagsEditor(tags: $draft.registeredTags)
                    } footer: {
                        Text("Only users with Sys.Modify on / may set or remove these tags.")
                    }
                }
                .navigationTitle("Registered Tags")
            } label: {
                LabeledContent("Registered Tags", value: draft.registeredTags.isEmpty ? String(localized: "None") : draft.registeredTags.joined(separator: ", "))
            }
            NavigationLink {
                TagColorsEditor(colors: $draft.tagColors, error: errors["tag-style"])
            } label: {
                LabeledContent("Tag Colors", value: draft.tagColors.isEmpty ? String(localized: "Automatic") : draft.tagColors.map(\.tag).joined(separator: ", "))
            }
            .accessibilityIdentifier("options.tagColors")
            FieldError(message: errors["tag-style"])
        } header: {
            Text("Tags")
        } footer: {
            Text("Shape and order apply to the web interface. Users without Sys.Modify on / may only set the tags allowed here.")
        }
    }

    private var haSection: some View {
        Section {
            Picker("On Node Shutdown", selection: $draft.haShutdownPolicy) {
                Text("Default (Conditional)").tag("")
                Text("Conditional").tag("conditional")
                Text("Freeze").tag("freeze")
                Text("Fail Over").tag("failover")
                Text("Migrate").tag("migrate")
            }
            Picker("Scheduler", selection: $draft.haScheduler) {
                Text("Default (Basic)").tag("")
                Text("Basic").tag("basic")
                Text("Static Load").tag("static")
                if supports(.haLoadBalancing) {
                    Text("Dynamic Load").tag("dynamic")
                }
            }
            Toggle("Rebalance on Start", isOn: $draft.haRebalanceOnStart)
            if supports(.haLoadBalancing) {
                Toggle("Automatic Rebalancing", isOn: $draft.haAutoRebalance)
                    .accessibilityIdentifier("options.autoRebalance")
            }
            if draft.haAutoRebalance, supports(.haLoadBalancing) {
                LabeledTextField(title: "Imbalance Threshold (%)", prompt: "30", text: $draft.haRebalanceThreshold, keyboard: .decimalPad)
                LabeledTextField(title: "Minimum Improvement (%)", prompt: "10", text: $draft.haRebalanceMargin, keyboard: .decimalPad)
                LabeledTextField(title: "Hold Duration (Rounds)", prompt: "3", text: $draft.haRebalanceHoldDuration, keyboard: .numberPad)
                Picker("Method", selection: $draft.haRebalanceMethod) {
                    Text("Default (Brute Force)").tag("")
                    Text("Brute Force").tag("bruteforce")
                    Text("TOPSIS").tag("topsis")
                }
            }
            FieldError(message: errors["crs"])
            Picker("Fencing", selection: $draft.fencing) {
                Text("Default (Watchdog)").tag("")
                Text("Watchdog").tag("watchdog")
                Text("Hardware").tag("hardware")
                Text("Both").tag("both")
            }
        } header: {
            Text("High Availability")
        } footer: {
            Text(supports(.haLoadBalancing)
                ? "What HA guests do when their node shuts down, and how a new node is chosen for them. Static load weighs the guests' CPU and memory settings, dynamic load their actual use. Rebalancing moves guests when nodes are loaded unevenly. Hardware fencing needs fence devices in /etc/pve/ha/fence.cfg."
                : "What HA guests do when their node shuts down, and how a new node is chosen for them. Static load weighs the guests' CPU and memory settings. Hardware fencing needs fence devices in /etc/pve/ha/fence.cfg.")
        }
    }

    private var twoFactorSection: some View {
        Section {
            LabeledTextField(title: "WebAuthn Name", prompt: "pve.example.com", text: $draft.webauthnName, identifier: "options.webauthnName")
            LabeledTextField(title: "WebAuthn ID", prompt: "pve.example.com", text: $draft.webauthnID, keyboard: .URL, identifier: "options.webauthnID")
                .textInputAutocapitalization(.never)
            LabeledTextField(title: "WebAuthn Origin", prompt: "https://pve.example.com:8006", text: $draft.webauthnOrigin, keyboard: .URL, identifier: "options.webauthnOrigin")
                .textInputAutocapitalization(.never)
            Toggle("Allow Subdomains", isOn: $draft.webauthnAllowsSubdomains)
            Button("Fill In for \(settings.connection.currentAddress.host)", systemImage: "wand.and.stars") {
                draft.fillWebauthn(host: settings.connection.currentAddress.host, port: settings.connection.currentAddress.port)
            }
            .accessibilityIdentifier("options.webauthnFill")
            FieldError(message: errors["webauthn"])
            LabeledTextField(title: "U2F AppID", prompt: "Origin", text: $draft.u2fAppID, keyboard: .URL)
                .textInputAutocapitalization(.never)
            LabeledTextField(title: "U2F Origin", prompt: "Automatic", text: $draft.u2fOrigin, keyboard: .URL)
                .textInputAutocapitalization(.never)
            FieldError(message: errors["u2f"])
        } header: {
            Text("Two-Factor Authentication")
        } footer: {
            Text("Security keys and passkeys (WebAuthn) are tied to the address users type into the browser. Changing the ID makes every registered key stop working; changing the origin may. U2F is the older standard, kept for existing keys.")
        }
    }

    private var locationSection: some View {
        Section {
            LabeledTextField(title: "Latitude", prompt: "52.2297", text: $draft.location.latitude, keyboard: .numbersAndPunctuation, identifier: "options.latitude")
            LabeledTextField(title: "Longitude", prompt: "21.0122", text: $draft.location.longitude, keyboard: .numbersAndPunctuation, identifier: "options.longitude")
            LabeledTextField(title: "Name", prompt: "None", text: $draft.location.name)
            FieldError(message: errors["location"])
        } header: {
            Text("Location")
        } footer: {
            Text("Where the cluster is, for the web interface's map. Nodes can have their own location.")
        }
    }

    private var otherSection: some View {
        Section {
            LabeledTextField(title: "Max. Workers", prompt: "Default", text: $draft.maxWorkers, keyboard: .numberPad)
            FieldError(message: errors["max_workers"])
            VStack(alignment: .leading, spacing: 6) {
                Text("Consent Text")
                TextEditor(text: $draft.consentText)
                    .frame(minHeight: 70)
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                TextEditor(text: $draft.notes)
                    .frame(minHeight: 90)
                    .font(.callout)
                    .accessibilityIdentifier("options.notes")
            }
        } header: {
            Text("Other")
        } footer: {
            Text("Workers limit how many guests start or stop at once per node. The consent text shows before signing in to the web interface; the notes are the datacenter's notes there.")
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
            try await settings.updateOptions(draft.changes(from: original))
            saved.toggle()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func bandwidthTitle(_ operation: String) -> LocalizedStringKey {
        switch operation {
        case "default": "Default"
        case "restore": "Restore"
        case "migration": "Migration"
        case "clone": "Clone"
        case "move": "Move Disk"
        default: LocalizedStringKey(operation)
        }
    }

    private static func keyboardName(_ code: String) -> String {
        let names: [String: String] = [
            "de": "German", "de-ch": "Swiss German", "da": "Danish", "en-gb": "English (UK)", "en-us": "English (US)", "es": "Spanish",
            "fi": "Finnish", "fr": "French", "fr-be": "Belgian French", "fr-ca": "Canadian French", "fr-ch": "Swiss French",
            "hu": "Hungarian", "is": "Icelandic", "it": "Italian", "ja": "Japanese", "lt": "Lithuanian", "mk": "Macedonian", "nl": "Dutch",
            "no": "Norwegian", "pl": "Polish", "pt": "Portuguese", "pt-br": "Portuguese (Brazil)", "sv": "Swedish", "sl": "Slovenian", "tr": "Turkish",
        ]
        return "\(names[code] ?? code) (\(code))"
    }

    private static func languageName(_ code: String) -> String {
        let identifier = code.replacingOccurrences(of: "ukr", with: "uk").replacingOccurrences(of: "kr", with: "ko")
        let name = Locale.current.localizedString(forIdentifier: identifier) ?? code
        return "\(name) (\(code))"
    }
}

/// Background and text colors of tags in the web interface.
private struct TagColorsEditor: View {
    @Binding var colors: [TagColor]
    var error: String?

    var body: some View {
        Form {
            Section {
                ForEach($colors) { $color in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Tag", text: $color.tag)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text(color.tag.isEmpty ? "tag" : color.tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(hex: color.background) ?? .gray, in: .capsule)
                                .foregroundStyle(Color(hex: color.text) ?? .white)
                        }
                        ColorPicker("Background", selection: Binding(get: { Color(hex: color.background) ?? .gray }, set: { color.background = $0.hex }), supportsOpacity: false)
                        Toggle("Own Text Color", isOn: Binding(get: { !color.text.isEmpty }, set: { color.text = $0 ? "FFFFFF" : "" }))
                        if !color.text.isEmpty {
                            ColorPicker("Text", selection: Binding(get: { Color(hex: color.text) ?? .white }, set: { color.text = $0.hex }), supportsOpacity: false)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { colors.remove(atOffsets: $0) }
                Button("Add Tag Color", systemImage: "plus") { colors.append(TagColor(tag: "", background: "1565C0")) }
                    .accessibilityIdentifier("options.tagColors.add")
                FieldError(message: error)
            } footer: {
                Text("Tags without a color here get one picked from their name. Without an own text color, the web interface picks black or white.")
            }
        }
        .navigationTitle("Tag Colors")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension Color {
    /// `RRGGBB`.
    init?(hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hex: String {
        let resolved = resolve(in: EnvironmentValues())
        let component = { (value: Float) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", component(resolved.red), component(resolved.green), component(resolved.blue))
    }
}
