import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Realms users sign in with: Linux PAM, Proxmox VE, LDAP, Active Directory and OpenID Connect.
struct RealmsView: View {
    let access: AccessControl
    @State private var creating: RealmType?
    @State private var removing: Realm?
    @State private var errorMessage: String?

    private var canModify: Bool { access.can("Realm.Allocate") }

    var body: some View {
        List {
            if let realms = access.realms {
                Section {
                    ForEach(realms) { realm in
                        NavigationLink {
                            RealmEditorLoader(access: access, realm: realm)
                        } label: {
                            RealmRow(realm: realm)
                        }
                        .accessibilityIdentifier("realm.\(realm.realm)")
                        .swipeActions {
                            if canModify, RealmType(rawValue: realm.type)?.canBeAdded == true {
                                Button("Remove", systemImage: "trash") { removing = realm }
                                    .tint(.red)
                            }
                        }
                    }
                } footer: {
                    Text("Users sign in as name@realm. LDAP and Active Directory realms can copy their users and groups into Proxmox VE.")
                }
            }
        }
        .overlay { if access.realms == nil { ProgressView() } }
        .navigationTitle("Realms")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    ForEach(RealmType.allCases.filter(\.canBeAdded)) { type in
                        Button(type.title) { creating = type }
                            .accessibilityIdentifier("realm.add.\(type.rawValue)")
                    }
                }
                .disabled(!canModify)
                .accessibilityIdentifier("realm.add")
            }
        }
        .refreshable { await access.load() }
        .sheet(item: $creating) { type in
            NavigationStack {
                RealmEditor(access: access, draft: RealmDraft(type: type), digest: nil, isNew: true)
            }
        }
        .confirmationDialog("Remove \(removing?.realm ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { realm in
            Button("Remove", role: .destructive) { Task { await remove(realm) } }
                .accessibilityIdentifier("realm.remove.confirm")
        } message: { _ in
            Text("Its users and groups stay in Proxmox VE, but nobody can sign in through it anymore.")
        }
        .accessError($errorMessage)
    }

    private func remove(_ realm: Realm) async {
        do {
            try await access.deleteRealm(realm.realm)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RealmRow: View {
    let realm: Realm

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(realm.realm)
                        .font(.body.weight(.medium))
                    if realm.isDefault { AccessBadge(text: "Default", color: .accentColor) }
                }
                Text([RealmType(rawValue: realm.type)?.title ?? realm.type, realm.comment].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch RealmType(rawValue: realm.type) {
        case .pam: "terminal"
        case .pve: "server.rack"
        case .ldap, .ad: "building.columns"
        case .openid: "person.badge.key"
        case nil: "questionmark.circle"
        }
    }
}

/// Loads a realm's settings, then shows the editor.
private struct RealmEditorLoader: View {
    let access: AccessControl
    let realm: Realm
    @State private var loaded: (draft: RealmDraft, digest: String?)?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let loaded {
                RealmEditor(access: access, draft: loaded.draft, digest: loaded.digest, isNew: false)
            } else if let errorMessage {
                ContentUnavailableView("Cannot Load the Realm", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(realm.realm)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let config = try await access.realmConfig(realm.realm)
                if let draft = RealmDraft(realm: realm.realm, config) {
                    loaded = (draft, config.digest)
                } else {
                    errorMessage = String(localized: "The app does not know realms of the type \(config.type).")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Creates or edits a realm. The sections follow the web interface's General and Sync Options tabs.
private struct RealmEditor: View {
    let access: AccessControl
    let original: RealmDraft
    let digest: String?
    let isNew: Bool
    @State private var draft: RealmDraft
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(access: AccessControl, draft: RealmDraft, digest: String?, isNew: Bool) {
        self.access = access
        self.digest = digest
        self.isNew = isNew
        original = draft
        _draft = State(initialValue: draft)
    }

    private var canModify: Bool { access.can("Realm.Allocate") }

    private var errors: [String: String] {
        (showsProblems ? draft.problems(isNew: isNew) : [:]).merging(fieldErrors) { _, server in server }
    }

    private var hasChanges: Bool { isNew || !draft.changes(from: original).isEmpty }

    var body: some View {
        Form {
            if !canModify {
                Section {
                    Label("Read only. Changing realms needs the Realm.Allocate privilege on /access/realm.", systemImage: "lock.fill")
                        .font(.subheadline)
                }
            }
            Group {
                generalSection
                switch draft.type {
                case .pam, .pve:
                    EmptyView()
                case .ldap, .ad:
                    DirectoryServerSection(draft: $draft, errors: errors)
                    DirectorySyncSection(draft: $draft, isNew: isNew, errors: errors)
                case .openid:
                    OpenIDSection(draft: $draft, isNew: isNew, errors: errors)
                }
                if draft.type.supportsTwoFactor {
                    RealmTwoFactorSection(twoFactor: $draft.twoFactor, error: errors["tfa"])
                }
            }
            .disabled(!canModify)
            if !isNew, draft.type.canSync {
                Section {
                    NavigationLink("Sync Users and Groups") {
                        RealmSyncView(access: access, realm: draft.realm, defaults: original.syncDefaults)
                    }
                    .disabled(!access.can("Realm.AllocateUser"))
                    .accessibilityIdentifier("realm.sync")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? Text("New \(draft.type.title) Realm") : Text(draft.realm))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!hasChanges)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    private var generalSection: some View {
        Section {
            if isNew {
                LabeledTextField(title: "Realm", prompt: "example", text: $draft.realm, identifier: "realm.id")
                FieldError(message: errors["realm"])
            } else {
                LabeledContent("Realm", value: draft.realm)
            }
            LabeledContent("Type", value: draft.type.title)
            LabeledTextField(title: "Comment", prompt: "None", text: $draft.comment)
            Toggle("Default Realm", isOn: $draft.isDefault)
        } footer: {
            Text("The default realm is preselected when signing in.")
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
                try await access.createRealm(draft)
            } else {
                try await access.updateRealm(draft.realm, draft.changes(from: original), digest: digest)
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

/// Where an LDAP or Active Directory server is, and how to find users on it.
private struct DirectoryServerSection: View {
    @Binding var draft: RealmDraft
    let errors: [String: String]

    var body: some View {
        Section {
            if draft.type == .ldap {
                LabeledTextField(title: "Base DN", prompt: "dc=example,dc=com", text: $draft.baseDN, identifier: "realm.baseDN")
                FieldError(message: errors["base_dn"])
                LabeledTextField(title: "User Attribute", prompt: "uid", text: $draft.userAttribute, identifier: "realm.userAttribute")
                FieldError(message: errors["user_attr"])
            } else {
                LabeledTextField(title: "Domain", prompt: "example.com", text: $draft.domain, keyboard: .URL, identifier: "realm.domain")
                FieldError(message: errors["domain"])
                Toggle("Case-Sensitive", isOn: $draft.isCaseSensitive)
            }
        } header: {
            Text(draft.type == .ldap ? "Directory" : "Domain")
        }
        Section {
            LabeledTextField(title: "Server", prompt: "ldap.example.com", text: $draft.server1, keyboard: .URL, identifier: "realm.server")
            FieldError(message: errors["server1"])
            LabeledTextField(title: "Fallback Server", prompt: "None", text: $draft.server2, keyboard: .URL)
            FieldError(message: errors["server2"])
            LabeledTextField(title: "Port", prompt: "Default", text: $draft.port, keyboard: .numberPad)
            FieldError(message: errors["port"])
            Picker("Mode", selection: $draft.mode) {
                Text("LDAP").tag("ldap")
                Text("LDAPS").tag("ldaps")
                Text("STARTTLS").tag("ldap+starttls")
            }
            if draft.mode != "ldap" {
                Toggle("Verify Certificate", isOn: $draft.verifyCertificate)
            }
            Toggle("Check Connection When Saving", isOn: $draft.checksConnection)
        } header: {
            Text("Server")
        } footer: {
            Text("Without verification, the connection is encrypted but the server's identity is not checked. Checking the connection needs the bind user below.")
        }
    }
}

/// The bind user, attributes, filters and default sync options of an LDAP or Active Directory realm.
private struct DirectorySyncSection: View {
    @Binding var draft: RealmDraft
    let isNew: Bool
    let errors: [String: String]

    var body: some View {
        Section {
            LabeledTextField(title: "Bind User", prompt: "cn=reader,dc=example,dc=com", text: $draft.bindDN)
            FieldError(message: errors["bind_dn"])
            LabeledContent("Bind Password") {
                SecureField("Bind Password", text: $draft.password, prompt: Text(isNew ? "None" : "Unchanged"))
                    .multilineTextAlignment(.trailing)
                    .textContentType(.oneTimeCode)
            }
            FieldError(message: errors["password"])
        } header: {
            Text("Bind User")
        } footer: {
            Text("The account the node uses to search the directory. Without one, it searches anonymously.")
        }
        Section {
            LabeledTextField(title: "Email Attribute", prompt: "mail", text: $draft.emailAttribute)
            LabeledTextField(title: "Group Name Attribute", prompt: "cn", text: $draft.groupNameAttribute)
            LabeledTextField(title: "User Classes", prompt: "Default", text: $draft.userClasses)
            LabeledTextField(title: "Group Classes", prompt: "Default", text: $draft.groupClasses)
            LabeledTextField(title: "User Filter", prompt: "None", text: $draft.userFilter)
            FieldError(message: errors["filter"])
            LabeledTextField(title: "Group Filter", prompt: "None", text: $draft.groupFilter)
            FieldError(message: errors["group_filter"])
        } header: {
            Text("Sync Options")
        } footer: {
            Text("Classes are comma-separated object classes. Filters are LDAP filters such as (memberOf=cn=pve,ou=groups,dc=example,dc=com).")
        }
        Section {
            SyncOptionFields(scope: $draft.syncDefaults.scope, enableNew: $draft.syncDefaults.enableNew, removeVanished: $draft.syncDefaults.removeVanished, allowsNoDefault: true)
            FieldError(message: errors["sync-defaults-options"])
        } header: {
            Text("Sync Defaults")
        } footer: {
            Text("Used by scheduled syncs, and preset when syncing from the app.")
        }
    }
}

/// Scope, new users and what vanished entries remove, for a sync or a realm's defaults.
private struct SyncOptionFields: View {
    @Binding var scope: String
    @Binding var enableNew: Bool?
    @Binding var removeVanished: Set<VanishedRemoval>
    /// Defaults may leave scope and new users unset.
    let allowsNoDefault: Bool

    var body: some View {
        Picker("Scope", selection: $scope) {
            if allowsNoDefault { Text("None").tag("") }
            Text("Users").tag("users")
            Text("Groups").tag("groups")
            Text("Users and Groups").tag("both")
        }
        Picker("Enable New Users", selection: $enableNew) {
            if allowsNoDefault { Text("Default (Yes)").tag(Bool?.none) }
            Text("Yes").tag(Bool?.some(true))
            Text("No").tag(Bool?.some(false))
        }
        ForEach(VanishedRemoval.allCases) { removal in
            Toggle(isOn: Binding(get: { removeVanished.contains(removal) }, set: { on in
                if on { removeVanished.insert(removal) } else { removeVanished.remove(removal) }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(removal.title)
                    Text(removal.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("sync.remove.\(removal.rawValue)")
        }
    }
}

extension VanishedRemoval {
    var title: LocalizedStringKey {
        switch self {
        case .acl: "Remove Permissions"
        case .entry: "Remove Users and Groups"
        case .properties: "Remove Properties"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .acl: "Of users and groups that vanished from the directory."
        case .entry: "That vanished from the directory."
        case .properties: "Such as an email address that vanished from a user."
        }
    }
}

/// Provider, client and claims of an OpenID Connect realm.
private struct OpenIDSection: View {
    @Binding var draft: RealmDraft
    let isNew: Bool
    let errors: [String: String]

    var body: some View {
        Section {
            LabeledTextField(title: "Issuer URL", prompt: "https://auth.example.com", text: $draft.issuerURL, keyboard: .URL, identifier: "realm.issuer")
            FieldError(message: errors["issuer-url"])
            LabeledTextField(title: "Client ID", prompt: "proxmox", text: $draft.clientID, identifier: "realm.clientID")
            FieldError(message: errors["client-id"])
            LabeledTextField(title: "Client Key", prompt: "None", text: $draft.clientKey)
            LabeledTextField(title: "Scopes", prompt: "email profile", text: $draft.scopes)
            Picker("Prompt", selection: $draft.prompt) {
                Text("Provider Default").tag("")
                ForEach(["none", "login", "consent", "select_account"], id: \.self) { Text(verbatim: $0).tag($0) }
            }
        } header: {
            Text("Provider")
        }
        Section {
            if isNew {
                Picker("Username Claim", selection: $draft.usernameClaim) {
                    Text("Default (subject)").tag("")
                    ForEach(["subject", "username", "email"], id: \.self) { Text(verbatim: $0).tag($0) }
                }
            } else {
                LabeledContent("Username Claim", value: draft.usernameClaim.isEmpty ? String(localized: "Default (subject)") : draft.usernameClaim)
            }
            Toggle("Create Users Automatically", isOn: $draft.autocreateUsers)
            LabeledTextField(title: "Groups Claim", prompt: "None", text: $draft.groupsClaim)
            Toggle("Create Groups Automatically", isOn: $draft.autocreateGroups)
            Toggle("Overwrite Groups at Sign-In", isOn: $draft.overwriteGroups)
        } header: {
            Text("Users and Groups")
        } footer: {
            Text("User names come from the username claim and cannot change once the realm exists.")
        }
        Section {
            LabeledTextField(title: "ACR Values", prompt: "None", text: $draft.acrValues)
            Toggle("Query Userinfo Endpoint", isOn: $draft.queriesUserinfo)
            LabeledTextField(title: "Audiences", prompt: "None", text: $draft.audiences)
        } header: {
            Text("Advanced")
        }
    }
}

/// A second factor the realm requires from all its users.
private struct RealmTwoFactorSection: View {
    @Binding var twoFactor: RealmTwoFactor
    let error: String?

    var body: some View {
        Section {
            Picker("Require", selection: $twoFactor.kind) {
                Text("None").tag(RealmTwoFactor.Kind.none)
                Text("OATH (TOTP)").tag(RealmTwoFactor.Kind.oath)
                Text("Yubico OTP").tag(RealmTwoFactor.Kind.yubico)
            }
            .accessibilityIdentifier("realm.tfa")
            switch twoFactor.kind {
            case .none:
                EmptyView()
            case .oath:
                LabeledTextField(title: "Digits", prompt: "6", text: $twoFactor.digits, keyboard: .numberPad)
                LabeledTextField(title: "Time Step", prompt: "30", text: $twoFactor.step, keyboard: .numberPad)
            case .yubico:
                LabeledTextField(title: "API Client ID", prompt: "Required", text: $twoFactor.yubicoID)
                LabeledTextField(title: "API Key", prompt: "Required", text: $twoFactor.yubicoKey)
                LabeledTextField(title: "Server URL", prompt: "YubiCloud", text: $twoFactor.yubicoURL, keyboard: .URL)
            }
            FieldError(message: error)
        } header: {
            Text("Required Second Factor")
        } footer: {
            Text("Applies to every user of the realm, on top of the second factors users add themselves. Each user then needs their key IDs set in the web interface.")
        }
    }
}

/// Copies users and groups from the directory, or previews what a sync would change.
private struct RealmSyncView: View {
    let access: AccessControl
    let realm: String
    @State private var scope: String
    @State private var enableNew: Bool?
    @State private var removeVanished: Set<VanishedRemoval>
    @State private var task: TaskCenter.TrackedTask?
    @State private var isStarting = false
    @State private var errorMessage: String?

    init(access: AccessControl, realm: String, defaults: RealmSyncOptions) {
        self.access = access
        self.realm = realm
        _scope = State(initialValue: defaults.scope.isEmpty ? "both" : defaults.scope)
        _enableNew = State(initialValue: defaults.enableNew ?? true)
        _removeVanished = State(initialValue: defaults.removeVanished)
    }

    private var isRunning: Bool {
        guard let task else { return false }
        return access.connection.tasks.tasks.first { $0.id == task.id }?.isRunning ?? false
    }

    var body: some View {
        Form {
            Section {
                SyncOptionFields(scope: $scope, enableNew: $enableNew, removeVanished: $removeVanished, allowsNoDefault: false)
            } footer: {
                Text("Synced groups get the realm as a suffix, such as admins-\(realm). A preview only lists the changes in the task log.")
            }
            .disabled(isRunning || isStarting)
            Section {
                Button("Preview") { Task { await sync(dryRun: true) } }
                    .accessibilityIdentifier("sync.preview")
                Button("Sync Now") { Task { await sync(dryRun: false) } }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("sync.start")
            }
            .disabled(isRunning || isStarting)
            if let task {
                Section {
                    HStack(spacing: 12) {
                        if isRunning { ProgressView() }
                        Text(isRunning ? "Syncing…" : "Finished")
                    }
                    NavigationLink("Show Task Log", value: ServerRoute.task(node: task.upid.node, upid: task.upid.rawValue))
                        .accessibilityIdentifier("sync.log")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Sync \(realm)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sync(dryRun: Bool) async {
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        do {
            task = try await access.syncRealm(realm, scope: scope, enableNew: enableNew ?? true, removeVanished: removeVanished, dryRun: dryRun)
            if let task, await access.connection.tasks.result(of: task.id) == .succeeded, !dryRun {
                await access.load()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
