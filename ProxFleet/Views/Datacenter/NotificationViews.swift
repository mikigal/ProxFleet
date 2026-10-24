import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Notification targets (where messages go) and matchers (which messages go where).
struct NotificationsView: View {
    @State private var settings: DatacenterSettings
    @State private var creatingEndpoint: NotificationEndpointType?
    @State private var creatingMatcher = false
    @State private var removingTarget: NotificationTarget?
    @State private var removingMatcher: NotificationMatcher?
    @State private var testResult: (title: String, message: String)?
    @State private var errorMessage: String?

    init(connection: ServerConnection) {
        _settings = State(initialValue: DatacenterSettings(connection: connection))
    }

    var body: some View {
        List {
            if let targets = settings.targets {
                Section {
                    ForEach(targets) { target in
                        NavigationLink {
                            if let type = target.endpointType {
                                EndpointEditorLoader(settings: settings, type: type, name: target.name)
                            }
                        } label: {
                            TargetRow(target: target)
                        }
                        .disabled(target.endpointType == nil)
                        .accessibilityIdentifier("target.\(target.name)")
                        .swipeActions {
                            if settings.canModifyEndpoints, !target.isBuiltIn {
                                Button("Remove", systemImage: "trash") { removingTarget = target }
                                    .tint(.red)
                            }
                            Button("Test", systemImage: "paperplane") { Task { await test(target) } }
                                .tint(.accentColor)
                        }
                        .contextMenu {
                            Button("Send Test Notification", systemImage: "paperplane") { Task { await test(target) } }
                        }
                    }
                } header: {
                    Text("Targets")
                } footer: {
                    Text("Swipe a target to send a test notification.")
                }
            }
            if let matchers = settings.matchers {
                Section {
                    ForEach(matchers) { matcher in
                        NavigationLink {
                            MatcherEditor(settings: settings, draft: NotificationMatcherDraft(matcher), digest: matcher.config.digest, isNew: false)
                        } label: {
                            MatcherRow(matcher: matcher)
                        }
                        .accessibilityIdentifier("matcher.\(matcher.name)")
                        .swipeActions {
                            if settings.canModifyNotifications, !matcher.isBuiltIn {
                                Button("Remove", systemImage: "trash") { removingMatcher = matcher }
                                    .tint(.red)
                            }
                        }
                    }
                } header: {
                    Text("Matchers")
                } footer: {
                    Text("A matcher sends notifications that fit its rules, such as failed backups, to its targets.")
                }
            }
        }
        .overlay {
            if let error = settings.loadError, settings.targets == nil {
                ContentUnavailableView("Cannot Load Notifications", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if settings.targets == nil {
                ProgressView()
            }
        }
        .navigationTitle("Notifications")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Section("Target") {
                        ForEach(NotificationEndpointType.allCases.filter { $0 != .webhook || settings.connection.supports(.webhookNotifications) }) { type in
                            Button(type.title, systemImage: type.systemImage) { creatingEndpoint = type }
                                .disabled(!settings.canModifyEndpoints)
                                .accessibilityIdentifier("target.add.\(type.rawValue)")
                        }
                    }
                    Button("Matcher", systemImage: "line.3.horizontal.decrease") { creatingMatcher = true }
                        .accessibilityIdentifier("matcher.add")
                }
                .disabled(!settings.canModifyNotifications)
                .accessibilityIdentifier("notifications.add")
            }
        }
        .refreshable { await settings.loadNotifications() }
        .task { await settings.loadNotifications() }
        .sheet(item: $creatingEndpoint) { type in
            NavigationStack {
                EndpointEditor(settings: settings, draft: NotificationEndpointDraft(type: type), digest: nil, isNew: true)
            }
        }
        .sheet(isPresented: $creatingMatcher) {
            NavigationStack {
                MatcherEditor(settings: settings, draft: NotificationMatcherDraft(), digest: nil, isNew: true)
            }
        }
        .confirmationDialog("Remove \(removingTarget?.name ?? "")?", isPresented: Binding(get: { removingTarget != nil }, set: { if !$0 { removingTarget = nil } }), titleVisibility: .visible, presenting: removingTarget) { target in
            Button("Remove", role: .destructive) { Task { await remove(target) } }
        } message: { _ in
            Text("Matchers stop sending to it.")
        }
        .confirmationDialog("Remove \(removingMatcher?.name ?? "")?", isPresented: Binding(get: { removingMatcher != nil }, set: { if !$0 { removingMatcher = nil } }), titleVisibility: .visible, presenting: removingMatcher) { matcher in
            Button("Remove", role: .destructive) { Task { await remove(matcher) } }
        }
        .alert(testResult?.title ?? "", isPresented: Binding(get: { testResult != nil }, set: { if !$0 { testResult = nil } })) {
            Button("OK") {}
        } message: {
            Text(testResult?.message ?? "")
        }
        .alert("Notification Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func test(_ target: NotificationTarget) async {
        do {
            try await settings.test(target.name)
            testResult = (String(localized: "Test Sent"), String(localized: "A test notification went to \(target.name)."))
        } catch {
            testResult = (String(localized: "Test Failed"), error.localizedDescription)
        }
    }

    private func remove(_ target: NotificationTarget) async {
        do {
            try await settings.deleteEndpoint(target)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ matcher: NotificationMatcher) async {
        do {
            try await settings.deleteMatcher(matcher.name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension NotificationEndpointType {
    var systemImage: String {
        switch self {
        case .sendmail: "envelope"
        case .smtp: "paperplane"
        case .gotify: "bell.badge"
        case .webhook: "link"
        }
    }
}

private struct TargetRow: View {
    let target: NotificationTarget

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: target.endpointType?.systemImage ?? "questionmark.circle")
                .font(.title3)
                .foregroundStyle(target.isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(target.name).font(.body.weight(.medium))
                    if target.isDisabled { AccessBadge(text: "Disabled") }
                    if target.isBuiltIn { AccessBadge(text: "Built In") }
                }
                Text([target.endpointType?.title ?? target.type, target.comment].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MatcherRow: View {
    let matcher: NotificationMatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(matcher.name).font(.body.weight(.medium))
                if matcher.isDisabled { AccessBadge(text: "Disabled") }
                if matcher.isBuiltIn { AccessBadge(text: "Built In") }
            }
            Text(String(localized: "To \(matcher.targets.isEmpty ? String(localized: "no targets") : matcher.targets.joined(separator: ", "))"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let comment = matcher.comment {
                Text(comment).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Endpoints

/// Loads an endpoint's settings, then shows the editor.
private struct EndpointEditorLoader: View {
    let settings: DatacenterSettings
    let type: NotificationEndpointType
    let name: String
    @State private var loaded: (draft: NotificationEndpointDraft, digest: String?)?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let loaded {
                EndpointEditor(settings: settings, draft: loaded.draft, digest: loaded.digest, isNew: false)
            } else if let errorMessage {
                ContentUnavailableView("Cannot Load the Target", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let config = try await settings.endpointConfig(type, name: name)
                loaded = (NotificationEndpointDraft(type: type, name: name, config), config.digest)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Creates or edits a sendmail, SMTP, Gotify or webhook endpoint.
private struct EndpointEditor: View {
    let settings: DatacenterSettings
    let original: NotificationEndpointDraft
    let digest: String?
    let isNew: Bool
    @State private var draft: NotificationEndpointDraft
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(settings: DatacenterSettings, draft: NotificationEndpointDraft, digest: String?, isNew: Bool) {
        self.settings = settings
        self.digest = digest
        self.isNew = isNew
        original = draft
        _draft = State(initialValue: draft)
    }

    private var errors: [String: String] {
        (showsProblems ? draft.problems(isNew: isNew) : [:]).merging(fieldErrors) { _, server in server }
    }

    private var hasChanges: Bool { isNew || !draft.changes(from: original).isEmpty }

    var body: some View {
        Form {
            Group {
                Section {
                    if isNew {
                        LabeledTextField(title: "Name", prompt: "ops-mail", text: $draft.name, identifier: "target.name")
                        FieldError(message: errors["name"])
                    } else {
                        LabeledContent("Name", value: draft.name)
                    }
                    LabeledContent("Type", value: draft.type.title)
                    Toggle("Enabled", isOn: $draft.isEnabled)
                    LabeledTextField(title: "Comment", prompt: "None", text: $draft.comment)
                }
                switch draft.type {
                case .sendmail:
                    recipientsSection
                    mailSection
                case .smtp:
                    smtpServerSection
                    recipientsSection
                    mailSection
                case .gotify:
                    gotifySection
                case .webhook:
                    WebhookSections(draft: $draft, isNew: isNew, errors: errors)
                }
            }
            .disabled(!settings.canModifyEndpoints)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? Text("New \(draft.type.title) Target") : Text(draft.name))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if settings.canModifyEndpoints {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!hasChanges)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    private var recipientsSection: some View {
        Section {
            TextListEditor(items: $draft.mailto, placeholder: "Add Address", keyboard: .emailAddress, identifier: "target.mailto")
            UserListPicker(connection: settings.connection, selection: $draft.mailtoUsers)
            FieldError(message: errors["mailto"])
        } header: {
            Text("Recipients")
        } footer: {
            Text("Users receive mail at the email address set for them in Users & Permissions.")
        }
    }

    private var mailSection: some View {
        Section {
            LabeledTextField(title: "From", prompt: draft.type == .smtp ? "pve@example.com" : "Default", text: $draft.fromAddress, keyboard: .emailAddress, identifier: "target.from")
            FieldError(message: errors["from-address"])
            LabeledTextField(title: "Author", prompt: "Proxmox VE", text: $draft.author)
        } header: {
            Text("Sender")
        }
    }

    private var smtpServerSection: some View {
        Section {
            LabeledTextField(title: "Server", prompt: "smtp.example.com", text: $draft.server, keyboard: .URL, identifier: "target.server")
            FieldError(message: errors["server"])
            Picker("Encryption", selection: $draft.mode) {
                Text("TLS").tag("tls")
                Text("STARTTLS").tag("starttls")
                Text("None (Insecure)").tag("insecure")
            }
            LabeledTextField(title: "Port", prompt: draft.mode == "tls" ? "465" : draft.mode == "starttls" ? "587" : "25", text: $draft.port, keyboard: .numberPad)
            FieldError(message: errors["port"])
            LabeledTextField(title: "User Name", prompt: "None", text: $draft.username)
            SecretField(title: "Password", text: $draft.secret, isStored: !isNew)
        } header: {
            Text("Server")
        }
    }

    private var gotifySection: some View {
        Section {
            LabeledTextField(title: "Server", prompt: "https://gotify.example.com", text: $draft.server, keyboard: .URL, identifier: "target.server")
            FieldError(message: errors["server"])
            SecretField(title: "Token", text: $draft.secret, isStored: !isNew, identifier: "target.token")
            FieldError(message: errors["token"])
        } header: {
            Text("Gotify")
        } footer: {
            Text("Create an application in Gotify and use its token.")
        }
    }

    private func save() async {
        showsProblems = true
        fieldErrors = [:]
        guard draft.problems(isNew: isNew).isEmpty else {
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if isNew {
                try await settings.createEndpoint(draft)
            } else {
                try await settings.updateEndpoint(draft.type, name: draft.name, draft.changes(from: original), digest: digest)
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

/// URL, method, body, headers and secrets of a webhook.
private struct WebhookSections: View {
    @Binding var draft: NotificationEndpointDraft
    let isNew: Bool
    let errors: [String: String]

    var body: some View {
        Section {
            Picker("Method", selection: $draft.method) {
                Text("POST").tag("post")
                Text("PUT").tag("put")
                Text("GET").tag("get")
            }
            LabeledTextField(title: "URL", prompt: "https://example.com/hook", text: $draft.url, keyboard: .URL, identifier: "target.url")
            FieldError(message: errors["url"])
        } header: {
            Text("Request")
        }
        Section {
            TextEditor(text: $draft.body)
                .font(.footnote.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: 100)
                .accessibilityIdentifier("target.body")
        } header: {
            Text("Body")
        } footer: {
            Text("URL, headers and body can use {{ title }}, {{ message }}, {{ severity }}, {{ timestamp }} and {{ secrets.name }}.")
        }
        Section {
            ForEach($draft.headers) { $header in
                PairRow(pair: $header, isSecret: false) { draft.headers.removeAll { $0.id == header.id } }
            }
            Button("Add Header", systemImage: "plus") { draft.headers.append(WebhookPair()) }
            FieldError(message: errors["header"])
        } header: {
            Text("Headers")
        }
        Section {
            ForEach($draft.secrets) { $secret in
                PairRow(pair: $secret, isSecret: true) { draft.secrets.removeAll { $0.id == secret.id } }
            }
            Button("Add Secret", systemImage: "plus") { draft.secrets.append(WebhookPair()) }
            FieldError(message: errors["secret"])
        } header: {
            Text("Secrets")
        } footer: {
            Text("Secrets are stored separately and never shown again. Leave a stored secret empty to keep it.")
        }
    }
}

private struct PairRow: View {
    @Binding var pair: WebhookPair
    let isSecret: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 6) {
                TextField("Name", text: $pair.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(pair.isStored)
                Group {
                    if isSecret {
                        SecureField(pair.isStored ? "Unchanged" : "Value", text: $pair.value)
                            .textContentType(.oneTimeCode)
                    } else {
                        TextField("Value", text: $pair.value)
                    }
                }
                .font(.callout)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.secondary)
            }
            Button("Remove", systemImage: "minus.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
                .buttonStyle(.plain)
        }
    }
}

/// A write-only secret: empty keeps the stored value.
private struct SecretField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let isStored: Bool
    var identifier: String?

    var body: some View {
        LabeledContent(title) {
            SecureField(title, text: $text, prompt: Text(isStored ? "Unchanged" : "None"))
                .multilineTextAlignment(.trailing)
                .textContentType(.oneTimeCode)
                .accessibilityIdentifier(identifier ?? "")
        }
    }
}

/// Free-text entries such as email addresses, with a field to add more.
private struct TextListEditor: View {
    @Binding var items: [String]
    let placeholder: LocalizedStringKey
    var keyboard: UIKeyboardType = .default
    var identifier: String?
    @State private var newItem = ""

    var body: some View {
        ForEach(items, id: \.self) { item in
            HStack {
                Text(item)
                Spacer()
                Button("Remove", systemImage: "minus.circle.fill") { items.removeAll { $0 == item } }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
            }
        }
        HStack {
            TextField(placeholder, text: $newItem)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(add)
                .accessibilityIdentifier(identifier ?? "")
            Button("Add", action: add)
                .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        let item = newItem.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else { return }
        if !items.contains(item) { items.append(item) }
        newItem = ""
    }
}

/// Users whose email address receives the mail.
private struct UserListPicker: View {
    let connection: ServerConnection
    @Binding var selection: [String]
    @State private var users: [AccessUser] = []

    var body: some View {
        NavigationLink {
            List {
                ForEach(allUsers, id: \.self) { userid in
                    Button {
                        if let index = selection.firstIndex(of: userid) { selection.remove(at: index) } else { selection.append(userid) }
                    } label: {
                        HStack {
                            Text(userid).foregroundStyle(.primary)
                            Spacer()
                            if selection.contains(userid) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            }
            .navigationTitle("Users")
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent("Users", value: selection.isEmpty ? String(localized: "None") : selection.joined(separator: ", "))
        }
        .task { users = await connection.load(PVE.users()) }
    }

    private var allUsers: [String] {
        let ids = users.map(\.userid)
        return selection.filter { !ids.contains($0) } + ids
    }
}

// MARK: - Matchers

/// Creates or edits a matcher: its targets and the rules notifications must fit.
private struct MatcherEditor: View {
    let settings: DatacenterSettings
    let original: NotificationMatcherDraft
    let digest: String?
    let isNew: Bool
    @State private var draft: NotificationMatcherDraft
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @State private var newCalendar = ""
    @Environment(\.dismiss) private var dismiss

    init(settings: DatacenterSettings, draft: NotificationMatcherDraft, digest: String?, isNew: Bool) {
        self.settings = settings
        self.digest = digest
        self.isNew = isNew
        original = draft
        _draft = State(initialValue: draft)
    }

    private var errors: [String: String] {
        (showsProblems ? draft.problems(isNew: isNew) : [:]).merging(fieldErrors) { _, server in server }
    }

    private var hasChanges: Bool { isNew || !draft.changes(from: original).isEmpty }

    private var knownFields: [String] {
        Array(Set(settings.fieldValues.map(\.field) + ["type", "hostname", "job-id"])).sorted()
    }

    var body: some View {
        Form {
            Group {
                Section {
                    if isNew {
                        LabeledTextField(title: "Name", prompt: "backup-failures", text: $draft.name, identifier: "matcher.name")
                        FieldError(message: errors["name"])
                    } else {
                        LabeledContent("Name", value: draft.name)
                    }
                    Toggle("Enabled", isOn: $draft.isEnabled)
                    LabeledTextField(title: "Comment", prompt: "None", text: $draft.comment)
                }
                Section {
                    ForEach(settings.targets ?? []) { target in
                        Toggle(isOn: Binding(get: { draft.targets.contains(target.name) }, set: { on in
                            if on { draft.targets.insert(target.name) } else { draft.targets.remove(target.name) }
                        })) {
                            Label(target.name, systemImage: target.endpointType?.systemImage ?? "questionmark.circle")
                        }
                        .accessibilityIdentifier("matcher.target.\(target.name)")
                    }
                    FieldError(message: errors["target"])
                } header: {
                    Text("Targets")
                }
                Section {
                    Picker("Match", selection: $draft.matchesAll) {
                        Text("All Rules").tag(true)
                        Text("Any Rule").tag(false)
                    }
                    Toggle("Invert", isOn: $draft.isInverted)
                } footer: {
                    Text("Without rules, every notification matches. Inverted, the matcher sends what does not match.")
                }
                Section {
                    ForEach(NotificationSeverity.allCases) { severity in
                        Toggle(severity.title, isOn: Binding(get: { draft.severities.contains(severity) }, set: { on in
                            if on { draft.severities.insert(severity) } else { draft.severities.remove(severity) }
                        }))
                        .accessibilityIdentifier("matcher.severity.\(severity.rawValue)")
                    }
                } header: {
                    Text("Severity")
                } footer: {
                    Text("None selected matches every severity.")
                }
                Section {
                    ForEach($draft.fields) { $rule in
                        FieldRuleRow(rule: $rule, fields: knownFields, values: settings.fieldValues) {
                            draft.fields.removeAll { $0.id == rule.id }
                        }
                    }
                    Button("Add Field Rule", systemImage: "plus") { draft.fields.append(MatcherFieldRule()) }
                        .accessibilityIdentifier("matcher.field.add")
                    FieldError(message: errors["match-field"])
                } header: {
                    Text("Fields")
                } footer: {
                    Text("Exact rules may list several values separated by commas, e.g. type = vzdump,replication.")
                }
                Section {
                    ForEach(draft.calendars, id: \.self) { calendar in
                        HStack {
                            Text(calendar).font(.callout.monospaced())
                            Spacer()
                            Button("Remove", systemImage: "minus.circle.fill") { draft.calendars.removeAll { $0 == calendar } }
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.red)
                                .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("mon..fri 8-17", text: $newCalendar)
                            .font(.callout.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addCalendar)
                        Button("Add", action: addCalendar)
                            .disabled(newCalendar.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Time")
                } footer: {
                    Text("Calendar events limit when the matcher sends, e.g. mon..fri 8-17 for working hours.")
                }
            }
            .disabled(!settings.canModifyNotifications)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? Text("New Matcher") : Text(draft.name))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if settings.canModifyNotifications {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!hasChanges)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    private func addCalendar() {
        let calendar = newCalendar.trimmingCharacters(in: .whitespaces)
        guard !calendar.isEmpty else { return }
        if !draft.calendars.contains(calendar) { draft.calendars.append(calendar) }
        newCalendar = ""
    }

    private func save() async {
        showsProblems = true
        fieldErrors = [:]
        guard draft.problems(isNew: isNew).isEmpty else {
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if isNew {
                try await settings.createMatcher(draft)
            } else {
                try await settings.updateMatcher(draft.name, draft.changes(from: original), digest: digest)
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

extension NotificationSeverity {
    var title: LocalizedStringKey {
        switch self {
        case .info: "Info"
        case .notice: "Notice"
        case .warning: "Warning"
        case .error: "Error"
        case .unknown: "Unknown"
        }
    }
}

/// One field rule: the field, exact or regular expression, and the value, with known values to pick from.
private struct FieldRuleRow: View {
    @Binding var rule: MatcherFieldRule
    let fields: [String]
    let values: [MatcherFieldValue]
    let onRemove: () -> Void

    private var known: [MatcherFieldValue] { values.filter { $0.field == rule.field } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Field", selection: $rule.field) {
                    if !fields.contains(rule.field) { Text(verbatim: rule.field).tag(rule.field) }
                    ForEach(fields, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .labelsHidden()
                Picker("Kind", selection: $rule.isRegex) {
                    Text("is").tag(false)
                    Text("matches").tag(true)
                }
                .labelsHidden()
                Spacer()
                Button("Remove", systemImage: "minus.circle.fill", action: onRemove)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
            }
            HStack {
                TextField(rule.isRegex ? "Regular expression" : "Value", text: $rule.value)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !rule.isRegex, !known.isEmpty {
                    Menu("Known Values", systemImage: "list.bullet") {
                        ForEach(known, id: \.self) { value in
                            Button(value.comment.map { "\(value.value) – \($0)" } ?? value.value) { add(value.value) }
                        }
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
    }

    /// Adds a value to an exact rule's list.
    private func add(_ value: String) {
        var list = rule.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !list.contains(value) { list.append(value) }
        rule.value = list.joined(separator: ",")
    }
}
