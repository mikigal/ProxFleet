import FleetCore
import PBSKit
import ProxmoxCore
import PVEKit
import SwiftUI

// MARK: - Users

/// Users of a backup server with their API tokens.
struct BackupServerUsersView: View {
    let access: BackupServerAccess
    @State private var creating = false

    var body: some View {
        List {
            if let users = access.users {
                Section {
                    ForEach(users) { user in
                        NavigationLink {
                            BackupServerUserView(access: access, userID: user.id)
                        } label: {
                            BackupServerUserRow(user: user)
                        }
                        .accessibilityIdentifier("user.\(user.id)")
                    }
                } footer: {
                    Text("Users of the Proxmox Backup realm (pbs) have passwords here; others sign in through their realm.")
                }
            }
        }
        .navigationTitle("Users")
        .overlay {
            if let error = access.loadError, access.users == nil {
                ContentUnavailableView("Cannot Load Users", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if access.users == nil {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!access.canManageUsers)
                    .accessibilityIdentifier("user.add")
            }
        }
        .refreshable { await access.load() }
        .task { await access.load() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                BackupServerUserEditor(access: access, user: nil)
            }
        }
    }
}

private struct BackupServerUserRow: View {
    let user: BackupServerUser

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: user.tokens.isEmpty ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                .font(.title3)
                .foregroundStyle(user.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user.id).font(.body.weight(.medium))
                    if !user.isEnabled {
                        Text("Disabled")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: .capsule)
                            .foregroundStyle(.secondary)
                    }
                }
                let details = [[user.firstName, user.lastName].compactMap { $0 }.joined(separator: " "), user.comment ?? ""].filter { !$0.isEmpty }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !user.tokens.isEmpty {
                    Text("^[\(user.tokens.count) API token](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One user: their settings, API tokens, permissions, password and second factors.
private struct BackupServerUserView: View {
    let access: BackupServerAccess
    let userID: String
    @State private var creatingToken = false
    @State private var addingPermission = false
    @State private var changingPassword = false
    @State private var twoFactors: AccessControl?
    @State private var errorMessage: String?

    private var user: BackupServerUser? { access.users?.first { $0.id == userID } }

    var body: some View {
        if let user {
            BackupServerUserEditor(access: access, user: user) {
                Section {
                    ForEach(user.tokens) { token in
                        NavigationLink {
                            BackupServerTokenEditor(access: access, userID: userID, token: token)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(token.id.split(separator: "!").last.map(String.init) ?? token.id)
                                    .foregroundStyle(token.isEnabled ? .primary : .secondary)
                                if let comment = token.comment {
                                    Text(comment).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("token.\(token.id)")
                    }
                    Button {
                        creatingToken = true
                    } label: {
                        Label("Add API Token", systemImage: "plus.circle")
                    }
                    .disabled(!access.canManageUsers && userID != access.currentUser)
                    .accessibilityIdentifier("token.add")
                } header: {
                    Text("API Tokens")
                } footer: {
                    Text("A token has only the permissions given to it, and never more than its user.")
                }
                Section {
                    ForEach(access.permissions(of: userID)) { entry in
                        BackupServerPermissionRow(entry: entry, showsAuthID: false)
                            .swipeActions {
                                if access.canModifyPermissions {
                                    Button("Remove", systemImage: "trash") { Task { await remove(entry) } }
                                        .tint(.red)
                                }
                            }
                    }
                    Button {
                        addingPermission = true
                    } label: {
                        Label("Add Permission", systemImage: "plus.circle")
                    }
                    .disabled(!access.canModifyPermissions)
                    .accessibilityIdentifier("user.permission.add")
                } header: {
                    Text("Permissions")
                }
                Section {
                    if user.id.hasSuffix("@pbs") {
                        Button("Change Password…") { changingPassword = true }
                            .disabled(!access.canManageUsers && userID != access.currentUser)
                            .accessibilityIdentifier("user.password")
                    }
                    if let twoFactors {
                        NavigationLink("Two-Factor Authentication") {
                            TwoFactorListView(access: twoFactors, userid: userID)
                        }
                        .accessibilityIdentifier("user.tfa")
                    }
                }
                ErrorSection(message: errorMessage)
            }
            .sheet(isPresented: $creatingToken) {
                NavigationStack {
                    BackupServerTokenCreationView(access: access, userID: userID)
                }
            }
            .sheet(isPresented: $addingPermission) {
                NavigationStack {
                    AddBackupServerPermissionView(access: access, authID: userID)
                }
            }
            .sheet(isPresented: $changingPassword) {
                NavigationStack {
                    BackupServerPasswordView(access: access, userID: userID)
                }
            }
            .task { if twoFactors == nil { twoFactors = AccessControl(connection: access.connection) } }
        } else {
            ContentUnavailableView("User Removed", systemImage: "person.crop.circle.badge.xmark")
        }
    }

    private func remove(_ entry: BackupServerACLEntry) async {
        do {
            try await access.removePermission(entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A user's settings, for a new user or an existing one, with extra sections below them.
private struct BackupServerUserEditor<Extra: View>: View {
    let access: BackupServerAccess
    let user: BackupServerUser?
    private let original: BackupServerUserDraft
    @State private var draft: BackupServerUserDraft
    private let extra: Extra

    init(access: BackupServerAccess, user: BackupServerUser?, @ViewBuilder extra: () -> Extra) {
        self.access = access
        self.user = user
        original = user.map(BackupServerUserDraft.init) ?? {
            var draft = BackupServerUserDraft()
            draft.userID = "@pbs"
            return draft
        }()
        _draft = State(initialValue: original)
        self.extra = extra()
    }

    private var isNew: Bool { user == nil }

    var body: some View {
        BackupServerJobForm(title: user?.id ?? String(localized: "New User"), isNew: isNew, lockMessage: lockMessage, hasChanges: hasChanges,
                            problems: problems, submit: save, delete: deleteAction,
                            deleteTitle: "Delete User", deleteMessage: "The user and their API tokens are removed, with their permissions.",
                            content: formContent)
    }

    private var lockMessage: String? {
        access.canManageUsers ? nil : missingPrivilegeMessage("Permissions.Modify", on: "/access/users")
    }

    private var hasChanges: Bool { !draft.changes(from: original).isEmpty }

    private func problems() -> [String: String] {
        draft.problems(isNew: isNew, realms: access.realms?.map(\.realm) ?? [])
    }

    /// A new user's name and realm, edited apart as in the web interface, making up `name@realm`.
    private var name: Binding<String> {
        Binding(get: { String(draft.userID.prefix { $0 != "@" }) }, set: { draft.userID = "\($0)@\(draft.realm)" })
    }

    private var realm: Binding<String> {
        Binding(get: { draft.realm }, set: { draft.userID = "\(String(draft.userID.prefix { $0 != "@" }))@\($0)" })
    }

    private var deleteAction: (() async throws(ConfigUpdateError) -> Void)? {
        guard !isNew, user?.id != "root@pam" else { return nil }
        return { () async throws(ConfigUpdateError) in try await remove() }
    }

    @ViewBuilder
    private func formContent(_ errors: [String: String]) -> some View {
        Section {
            if isNew {
                LabeledTextField(title: "User Name", prompt: "backup", text: name, identifier: "user.name")
                Picker("Realm", selection: realm) {
                    ForEach(access.realms ?? []) { Text($0.realm).tag($0.realm) }
                    if !(access.realms ?? []).contains(where: { $0.realm == draft.realm }) { Text(draft.realm).tag(draft.realm) }
                }
                .accessibilityIdentifier("user.realm")
                FieldError(message: errors["userid"])
            }
            Toggle("Enabled", isOn: $draft.isEnabled)
                .disabled(user?.id == access.currentUser)
            Toggle("Expires", isOn: Binding(get: { draft.expires != nil }, set: { draft.expires = $0 ? Date().addingTimeInterval(86_400 * 365) : nil }))
            if let date = draft.expires {
                DatePicker("Expiry Date", selection: Binding(get: { date }, set: { draft.expires = $0 }), displayedComponents: .date)
            }
        } footer: {
            if isNew {
                Text("Users of other realms (pam, LDAP, Active Directory, OpenID) sign in with their realm's password.")
            }
        }
        if isNew, draft.realm == "pbs" {
            Section("Password") {
                // Another user's password: iOS must not offer a strong password or save it as one of the device
                // owner's own. Without a content type it still guesses an account form; one-time code opts out.
                SecureField("Password", text: $draft.password)
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("user.newPassword")
                SecureField("Confirm Password", text: $draft.passwordConfirmation)
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("user.confirmPassword")
                FieldError(message: errors["password"])
            }
        }
        Section("Details") {
            LabeledTextField(title: "First Name", prompt: "None", text: $draft.firstName)
            LabeledTextField(title: "Last Name", prompt: "None", text: $draft.lastName)
            LabeledTextField(title: "Email", prompt: "None", text: $draft.email, keyboard: .emailAddress, identifier: "user.email")
            FieldError(message: errors["email"])
            LabeledTextField(title: "Comment", prompt: "None", text: $draft.comment, identifier: "user.comment")
        }
        extra
    }

    private func save() async throws(ConfigUpdateError) {
        if let user {
            try await access.updateUser(user.id, draft.changes(from: original))
        } else {
            try await access.createUser(draft)
        }
    }

    private func remove() async throws(ConfigUpdateError) {
        if let user { try await access.deleteUser(user.id) }
    }
}

extension BackupServerUserEditor where Extra == EmptyView {
    init(access: BackupServerAccess, user: BackupServerUser?) {
        self.init(access: access, user: user) { EmptyView() }
    }
}

private struct BackupServerPasswordView: View {
    let access: BackupServerAccess
    let userID: String
    @State private var password = ""
    @State private var repeated = ""
    @State private var confirmation = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        password.count >= 8 && password == repeated && (!access.needsPasswordConfirmation || !confirmation.isEmpty)
    }

    var body: some View {
        Form {
            Section {
                SecureField("New Password", text: $password)
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("password.new")
                SecureField("Repeat Password", text: $repeated)
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("password.repeat")
            } footer: {
                Text("At least 8 characters.")
            }
            if access.needsPasswordConfirmation {
                Section {
                    SecureField("Your Password", text: $confirmation)
                        .textContentType(.oneTimeCode)
                } footer: {
                    Text("Confirm with the password of \(access.currentUser).")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Change Password")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Save", isWorking: isSaving) { Task { await save() } }
                    .disabled(!isValid)
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await access.changePassword(of: userID, to: password, confirmation: access.needsPasswordConfirmation ? confirmation : nil)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Tokens

private struct BackupServerTokenCreationView: View {
    let access: BackupServerAccess
    let userID: String
    @State private var draft = BackupServerTokenDraft()
    @State private var created: BackupServerCreatedToken?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let created {
                BackupServerTokenSecretSection(token: created)
            } else {
                Section {
                    LabeledTextField(title: "Token Name", prompt: "sync", text: $draft.name, identifier: "token.name")
                    LabeledTextField(title: "Comment", prompt: "None", text: $draft.comment)
                    Toggle("Enabled", isOn: $draft.isEnabled)
                    Toggle("Expires", isOn: Binding(get: { draft.expires != nil }, set: { draft.expires = $0 ? Date().addingTimeInterval(86_400 * 365) : nil }))
                    if let date = draft.expires {
                        DatePicker("Expiry Date", selection: Binding(get: { date }, set: { draft.expires = $0 }), in: Date()..., displayedComponents: .date)
                    }
                } footer: {
                    Text("The token starts without permissions; give it some under Permissions as \(userID)!\(draft.name.isEmpty ? "token" : draft.name).")
                }
                ErrorSection(message: errorMessage)
            }
        }
        .navigationTitle("New API Token")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(created != nil || isSaving)
        .toolbar {
            if created == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton("Create", isWorking: isSaving) { Task { await create() } }
                        .disabled(!draft.problems.isEmpty)
                        .accessibilityIdentifier("token.create")
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("token.done")
                }
            }
        }
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        do {
            created = try await access.createToken(of: userID, draft)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A token's secret right after it was made: shown only this once.
private struct BackupServerTokenSecretSection: View {
    let token: BackupServerCreatedToken

    var body: some View {
        Section {
            LabeledContent("Token ID") { Text(token.tokenID).font(.callout.monospaced()).textSelection(.enabled) }
            LabeledContent("Secret") { Text(token.secret).font(.callout.monospaced()).textSelection(.enabled) }
                .accessibilityIdentifier("token.secret")
            Button("Copy Secret", systemImage: "doc.on.doc") { UIPasteboard.general.string = token.secret }
        } footer: {
            Text("Store the secret now: the server does not show it again. Clients sign in with \(token.tokenID) and the secret.")
        }
    }
}

private struct BackupServerTokenEditor: View {
    let access: BackupServerAccess
    let userID: String
    let token: BackupServerUser.Token
    private let original: BackupServerTokenDraft
    @State private var draft: BackupServerTokenDraft
    @State private var regenerated: BackupServerCreatedToken?
    @State private var confirmsRegeneration = false
    @State private var errorMessage: String?

    init(access: BackupServerAccess, userID: String, token: BackupServerUser.Token) {
        self.access = access
        self.userID = userID
        self.token = token
        original = BackupServerTokenDraft(token)
        _draft = State(initialValue: original)
    }

    private var canChange: Bool { access.canManageUsers || userID == access.currentUser }

    var body: some View {
        BackupServerJobForm(title: original.name, isNew: false,
                            lockMessage: canChange ? nil : missingPrivilegeMessage("Permissions.Modify", on: "/access/users"),
                            hasChanges: !draft.changes(from: original).isEmpty, problems: { [:] },
                            submit: save, delete: remove,
                            deleteTitle: "Delete Token", deleteMessage: "Clients using the token can no longer sign in.") { _ in
            Section {
                LabeledContent("Token ID", value: token.id)
                LabeledTextField(title: "Comment", prompt: "None", text: $draft.comment)
                Toggle("Enabled", isOn: $draft.isEnabled)
                Toggle("Expires", isOn: Binding(get: { draft.expires != nil }, set: { draft.expires = $0 ? Date().addingTimeInterval(86_400 * 365) : nil }))
                if let date = draft.expires {
                    DatePicker("Expiry Date", selection: Binding(get: { date }, set: { draft.expires = $0 }), displayedComponents: .date)
                }
            }
            Section {
                ForEach(access.permissions(of: token.id)) { entry in
                    BackupServerPermissionRow(entry: entry, showsAuthID: false)
                }
                if access.permissions(of: token.id).isEmpty {
                    Text("No permissions.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Permissions")
            }
            if access.connection.supports(backupServer: .regenerateTokenSecret) {
                if let regenerated {
                    BackupServerTokenSecretSection(token: regenerated)
                } else {
                    Section {
                        Button("Regenerate Secret…") { confirmsRegeneration = true }
                            .accessibilityIdentifier("token.regenerate")
                    } footer: {
                        Text("A new secret with the same permissions; the old one stops working.")
                    }
                }
            }
            ErrorSection(message: errorMessage)
        }
        .confirmationDialog("Regenerate the secret?", isPresented: $confirmsRegeneration, titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) { Task { await regenerate() } }
        } message: {
            Text("Clients using the current secret can no longer sign in.")
        }
    }

    private func save() async throws(ConfigUpdateError) {
        try await access.updateToken(of: userID, name: original.name, draft.changes(from: original))
    }

    private func remove() async throws(ConfigUpdateError) {
        try await access.deleteToken(of: userID, name: original.name)
    }

    private func regenerate() async {
        do {
            regenerated = try await access.regenerateToken(of: userID, name: original.name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Permissions

struct BackupServerPermissionRow: View {
    let entry: BackupServerACLEntry
    var showsAuthID = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(showsAuthID ? entry.authID : entry.path)
                    .font(.body.weight(.medium))
                Spacer()
                Text(entry.role)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(showsAuthID ? entry.path : (entry.propagates ? String(localized: "Also below") : String(localized: "Only this path")))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Every permission of the backup server, by path.
struct BackupServerPermissionsView: View {
    let access: BackupServerAccess
    @State private var adding = false
    @State private var errorMessage: String?

    private var paths: [String] { Array(Set((access.acl ?? []).map(\.path))).sorted() }

    var body: some View {
        List {
            ForEach(paths, id: \.self) { path in
                Section(path) {
                    ForEach((access.acl ?? []).filter { $0.path == path }) { entry in
                        BackupServerPermissionRow(entry: entry)
                            .swipeActions {
                                if access.canModifyPermissions {
                                    Button("Remove", systemImage: "trash") { Task { await remove(entry) } }
                                        .tint(.red)
                                }
                            }
                            .accessibilityIdentifier("permission.\(entry.path).\(entry.authID)")
                    }
                }
            }
        }
        .navigationTitle("Permissions")
        .overlay {
            if access.acl == nil {
                ProgressView()
            } else if access.acl?.isEmpty == true {
                ContentUnavailableView("No Permissions", systemImage: "person.badge.key", description: Text("Only root@pam can do anything yet."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { adding = true }
                    .disabled(!access.canModifyPermissions)
                    .accessibilityIdentifier("permission.add")
            }
        }
        .refreshable { await access.load() }
        .task { await access.load() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                AddBackupServerPermissionView(access: access, authID: nil)
            }
        }
        .alert("Cannot Remove the Permission", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func remove(_ entry: BackupServerACLEntry) async {
        do {
            try await access.removePermission(entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Gives a user or token a role on a path, with the server's paths to choose from.
private struct AddBackupServerPermissionView: View {
    let access: BackupServerAccess
    /// Fixed when adding from a user's screen.
    let authID: String?
    @State private var path = "/datastore"
    @State private var selectedAuthID = ""
    @State private var role = "DatastoreReader"
    @State private var propagates = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var suggestedPaths: [String] {
        let stores = access.connection.backupServer?.datastores.map { "/datastore/\($0.store)" } ?? []
        return ["/", "/access", "/datastore"] + stores + ["/remote", "/system", "/system/disks", "/system/network", "/system/tasks"]
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Path", text: $path)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("permission.path")
                    Menu {
                        ForEach(suggestedPaths, id: \.self) { suggestion in
                            Button(suggestion) { path = suggestion }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Paths")
                }
                if authID == nil {
                    Picker("User or Token", selection: $selectedAuthID) {
                        if selectedAuthID.isEmpty { Text("Choose").tag("") }
                        ForEach(access.authIDs, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("permission.user")
                }
                Picker("Role", selection: $role) {
                    ForEach(access.roles ?? [], id: \.id) { Text($0.id).tag($0.id) }
                    if !(access.roles ?? []).contains(where: { $0.id == role }) { Text(role).tag(role) }
                }
                .accessibilityIdentifier("permission.role")
                Toggle("Propagate", isOn: $propagates)
            } footer: {
                Text(roleDescription)
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Add Permission")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Add", isWorking: isSaving) { Task { await add() } }
                    .disabled((authID ?? selectedAuthID).isEmpty || !path.hasPrefix("/"))
                    .accessibilityIdentifier("permission.save")
            }
        }
    }

    private var roleDescription: String {
        let privileges = access.roles?.first { $0.id == role }?.privileges ?? []
        let list = privileges.isEmpty ? String(localized: "no privileges") : privileges.joined(separator: ", ")
        return propagates
            ? String(localized: "\(role) grants \(list) on the path and everything below it.")
            : String(localized: "\(role) grants \(list) on this path only.")
    }

    private func add() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await access.addPermission(BackupServerACLEntry(path: path, authID: authID ?? selectedAuthID, role: role, propagates: propagates))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Realms

extension BackupServerRealmDraft.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .ldap: "LDAP"
        case .ad: "Active Directory"
        case .openid: "OpenID Connect"
        case .pam: "Linux PAM"
        case .pbs: "Proxmox Backup Server"
        }
    }
}

/// Where users sign in: PAM, the server's own users, LDAP, Active Directory and OpenID Connect.
struct BackupServerRealmsView: View {
    let access: BackupServerAccess
    @State private var creating: BackupServerRealmDraft.Kind?

    var body: some View {
        List {
            ForEach(access.realms ?? []) { realm in
                if let kind = BackupServerRealmDraft.Kind(rawValue: realm.type) {
                    NavigationLink {
                        BackupServerRealmLoader(access: access, kind: kind, realm: realm.realm)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(realm.realm).font(.body.weight(.medium))
                                Text(kind.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if realm.isDefault {
                                Text("Default").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("realm.\(realm.realm)")
                }
            }
        }
        .navigationTitle("Realms")
        .overlay {
            if access.realms == nil { ProgressView() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    ForEach([BackupServerRealmDraft.Kind.ldap, .ad, .openid]) { kind in
                        Button(kind.title) { creating = kind }
                            .accessibilityIdentifier("realm.add.\(kind.rawValue)")
                    }
                }
                .disabled(!access.canManageRealms)
                .accessibilityIdentifier("realm.add")
            }
        }
        .refreshable { await access.load() }
        .task { await access.load() }
        .sheet(item: $creating) { kind in
            NavigationStack {
                BackupServerRealmEditor(access: access, draft: BackupServerRealmDraft(kind: kind), digest: nil, isNew: true)
            }
        }
    }
}

private struct BackupServerRealmLoader: View {
    let access: BackupServerAccess
    let kind: BackupServerRealmDraft.Kind
    let realm: String
    @State private var loaded: Digested<BackupServerRealmConfig>?
    @State private var errorMessage: String?

    var body: some View {
        if let loaded {
            BackupServerRealmEditor(access: access, draft: BackupServerRealmDraft(kind: kind, realm: realm, config: loaded.value), digest: loaded.digest, isNew: false)
        } else if let errorMessage {
            ContentUnavailableView("Cannot Load the Realm", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else {
            ProgressView()
                .task {
                    do {
                        loaded = try await access.realmConfig(kind, realm)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
        }
    }
}

private struct BackupServerRealmEditor: View {
    let access: BackupServerAccess
    private let original: BackupServerRealmDraft
    private let digest: String?
    private let isNew: Bool
    @State private var draft: BackupServerRealmDraft
    @State private var syncing = false

    init(access: BackupServerAccess, draft: BackupServerRealmDraft, digest: String?, isNew: Bool) {
        self.access = access
        original = draft
        self.digest = digest
        self.isNew = isNew
        _draft = State(initialValue: draft)
    }

    private var kind: BackupServerRealmDraft.Kind { draft.kind }

    var body: some View {
        BackupServerJobForm(title: isNew ? String(localized: "New Realm") : draft.realm, isNew: isNew, lockMessage: lockMessage, hasChanges: hasChanges,
                            problems: problems, submit: save, delete: deleteAction,
                            deleteTitle: "Delete Realm", deleteMessage: "Its users can no longer sign in. The users and their permissions stay.",
                            content: formContent)
        .sheet(isPresented: $syncing) {
            NavigationStack {
                BackupServerRealmSyncView(access: access, realm: draft.realm)
            }
        }
    }

    private var lockMessage: String? {
        access.canManageRealms ? nil : missingPrivilegeMessage("Realm.Allocate", on: "/access/domains")
    }

    private var hasChanges: Bool { !draft.update(from: original, digest: nil).isEmpty }

    private func problems() -> [String: String] { draft.problems(isNew: isNew) }

    private var deleteAction: (() async throws(ConfigUpdateError) -> Void)? {
        guard !isNew, !kind.isBuiltIn else { return nil }
        return { () async throws(ConfigUpdateError) in try await remove() }
    }

    @ViewBuilder
    private func formContent(_ errors: [String: String]) -> some View {
        Section {
            if isNew {
                LabeledTextField(title: "Realm", prompt: kind == .openid ? "sso" : "company", text: $draft.realm, identifier: "realm.name")
                FieldError(message: errors["realm"])
            }
            LabeledContent("Type") { Text(kind.title) }
            LabeledTextField(title: "Comment", prompt: "None", text: $draft.comment, identifier: "realm.comment")
            Toggle("Default Realm", isOn: $draft.isDefault)
        } footer: {
            Text("The default realm is preselected on the web interface's login.")
        }
        if kind.isDirectory { directorySections(errors) }
        if kind == .openid { openIDSections(errors) }
        if kind.isDirectory, !isNew {
            Section {
                Button("Sync Users…") { syncing = true }
                    .accessibilityIdentifier("realm.sync")
            } footer: {
                Text("Creates and updates users from the directory, as the web interface's Sync does.")
            }
        }
    }

    @ViewBuilder
    private func directorySections(_ errors: [String: String]) -> some View {
        Section {
            LabeledTextField(title: "Server", prompt: "ldap.example.com", text: $draft.server1, keyboard: .URL, identifier: "realm.server1")
            FieldError(message: errors["server1"])
            LabeledTextField(title: "Fallback Server", prompt: "None", text: $draft.server2, keyboard: .URL)
            OptionalNumberField(title: "Port", placeholder: "Default", value: $draft.port)
            FieldError(message: errors["port"])
            Picker("Mode", selection: $draft.mode) {
                Text("LDAP").tag("ldap")
                Text("STARTTLS").tag("ldap+starttls")
                Text("LDAPS").tag("ldaps")
            }
            if draft.mode != "ldap" {
                Toggle("Verify Certificate", isOn: $draft.verifiesCertificate)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("The server connects to the directory when the realm is saved, so it must be reachable.")
        }
        Section {
            LabeledTextField(title: "Base DN", prompt: kind == .ad ? "Automatic" : "dc=example,dc=com", text: $draft.baseDN, identifier: "realm.baseDN")
            FieldError(message: errors["base-dn"])
            if kind == .ldap {
                LabeledTextField(title: "User Attribute", prompt: "uid", text: $draft.userAttribute, identifier: "realm.userAttr")
                FieldError(message: errors["user-attr"])
            }
            LabeledTextField(title: "Bind User", prompt: "Anonymous", text: $draft.bindDN)
            LabeledContent(isNew ? "Bind Password" : "New Bind Password") {
                SecureField("Password", text: $draft.password, prompt: Text(isNew ? "None" : "Unchanged"))
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Directory")
        }
        Section {
            LabeledTextField(title: "User Filter", prompt: "None", text: $draft.filter)
            LabeledTextField(title: "User Classes", prompt: "Default", text: $draft.userClasses)
            LabeledTextField(title: "Attributes", prompt: "email=mail", text: $draft.syncAttributes)
            LabeledTextField(title: "Sync Defaults", prompt: "None", text: $draft.syncDefaults)
        } header: {
            Text("Sync")
        } footer: {
            Text("Attributes map user fields to directory attributes (email, firstname, lastname). Sync defaults are the web interface's, e.g. enable-new=1,remove-vanished=acl;entry.")
        }
    }

    @ViewBuilder
    private func openIDSections(_ errors: [String: String]) -> some View {
        Section {
            LabeledTextField(title: "Issuer URL", prompt: "https://sso.example.com/realms/main", text: $draft.issuerURL, keyboard: .URL, identifier: "realm.issuer")
            FieldError(message: errors["issuer-url"])
            LabeledTextField(title: "Client ID", prompt: "proxmox-backup", text: $draft.clientID, identifier: "realm.clientID")
            FieldError(message: errors["client-id"])
            LabeledContent(isNew ? "Client Key" : "New Client Key") {
                SecureField("Client Key", text: $draft.clientKey, prompt: Text(isNew ? "None" : "Unchanged"))
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Provider")
        }
        Section {
            LabeledTextField(title: "Scopes", prompt: "email profile", text: $draft.scopes)
            LabeledTextField(title: "Username Claim", prompt: "sub", text: $draft.usernameClaim)
            LabeledTextField(title: "Prompt", prompt: "None", text: $draft.prompt)
            LabeledTextField(title: "ACR Values", prompt: "None", text: $draft.acrValues)
            Toggle("Create Users Automatically", isOn: $draft.autocreate)
        } header: {
            Text("Options")
        }
    }

    private func save() async throws(ConfigUpdateError) {
        if isNew {
            try await access.createRealm(draft)
        } else {
            try await access.updateRealm(kind, draft.realm, draft.update(from: original, digest: digest))
        }
    }

    private func remove() async throws(ConfigUpdateError) {
        try await access.deleteRealm(kind, draft.realm)
    }
}

private struct BackupServerRealmSyncView: View {
    let access: BackupServerAccess
    let realm: String
    @State private var dryRun = true
    @State private var enableNew = true
    @State private var removals: Set<RealmSyncRemoval> = []
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Toggle("Dry Run", isOn: $dryRun)
                    .accessibilityIdentifier("sync.dryRun")
                Toggle("Enable New Users", isOn: $enableNew)
            } footer: {
                Text("A dry run only lists in its task log what would change.")
            }
            Section {
                ForEach(RealmSyncRemoval.allCases) { removal in
                    Toggle(isOn: Binding(get: { removals.contains(removal) }, set: { on in
                        if on { removals.insert(removal) } else { removals.remove(removal) }
                    })) {
                        switch removal {
                        case .acl: Text("Permissions")
                        case .entry: Text("Users")
                        case .properties: Text("User Properties")
                        }
                    }
                }
            } header: {
                Text("Remove Vanished")
            } footer: {
                Text("What to remove for users who are no longer in the directory, or whose attributes are gone.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Sync \(realm)")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Sync", isWorking: isWorking) { Task { await sync() } }
                    .accessibilityIdentifier("sync.start")
            }
        }
    }

    private func sync() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await access.syncRealm(realm, dryRun: dryRun, enableNew: enableNew, removeVanished: removals)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
