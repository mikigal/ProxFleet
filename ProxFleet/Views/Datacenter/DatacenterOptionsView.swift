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
        } header: {
            Text("Network")
        } footer: {
            Text("The proxy is used for downloads such as updates and templates. Insecure migration skips the SSH tunnel; use it only on a private network.")
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
            }
        } header: {
            Text("High Availability")
        } footer: {
            Text("What HA guests do when their node shuts down, and how a new node is chosen for them. Static load weighs the guests' CPU and memory settings.")
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
