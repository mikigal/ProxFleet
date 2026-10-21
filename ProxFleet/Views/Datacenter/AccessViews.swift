import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Users, groups, roles and permissions of the datacenter.
struct AccessHubView: View {
    @State private var access: AccessControl

    init(connection: ServerConnection) {
        _access = State(initialValue: AccessControl(connection: connection))
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    UsersView(access: access)
                } label: {
                    MoreRow(title: "Users", systemImage: "person.2", color: .blue, hint: access.users.map { String($0.count) })
                }
                .accessibilityIdentifier("access.users")
                NavigationLink {
                    GroupsView(access: access)
                } label: {
                    MoreRow(title: "Groups", systemImage: "person.3", color: .indigo, hint: access.groups.map { String($0.count) })
                }
                .accessibilityIdentifier("access.groups")
                NavigationLink {
                    RolesView(access: access)
                } label: {
                    MoreRow(title: "Roles", systemImage: "key", color: .orange, hint: access.roles.map { String($0.count) })
                }
                .accessibilityIdentifier("access.roles")
                NavigationLink {
                    PermissionsView(access: access)
                } label: {
                    MoreRow(title: "Permissions", systemImage: "lock.shield", color: .green, hint: access.acl.map { String($0.count) })
                }
                .accessibilityIdentifier("access.permissions")
            } footer: {
                Text("A permission grants a role, a set of privileges, to a user, group or API token on a path such as /vms/100. Paths inherit permissions from above when they propagate.")
            }
            if let error = access.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Users & Permissions")
        .refreshable { await access.load() }
        .task { await access.load() }
    }
}

/// An alert-style error for the access screens.
private struct AccessErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("Access Error", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
    }
}

private extension View {
    func accessError(_ message: Binding<String?>) -> some View { modifier(AccessErrorAlert(message: message)) }
}

private struct Badge: View {
    let text: LocalizedStringKey
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

// MARK: - Users

private struct UsersView: View {
    let access: AccessControl
    @State private var creating = false

    var body: some View {
        List {
            ForEach(access.users ?? []) { user in
                NavigationLink {
                    UserDetailView(access: access, userid: user.userid)
                } label: {
                    UserRow(user: user)
                }
                .accessibilityIdentifier("user.\(user.userid)")
            }
        }
        .overlay { if access.users == nil { ProgressView() } }
        .navigationTitle("Users")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!access.can("User.Modify"))
                    .accessibilityIdentifier("user.add")
            }
        }
        .refreshable { await access.load() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                UserEditor(access: access, user: nil)
            }
        }
    }
}

private struct UserRow: View {
    let user: AccessUser

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: user.userid == "root@pam" ? "person.badge.key.fill" : "person.crop.circle")
                .font(.title3)
                .foregroundStyle(user.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user.userid)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if !user.isEnabled { Badge(text: "Disabled") }
                    if user.isExpired() { Badge(text: "Expired", color: .orange) }
                }
                let details = [user.displayName, user.groups.isEmpty ? nil : user.groups.joined(separator: ", "), user.comment].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !user.tokens.isEmpty {
                Label("\(user.tokens.count)", systemImage: "key.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("^[\(user.tokens.count) API token](inflect: true)")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UserDetailView: View {
    let access: AccessControl
    let userid: String
    @State private var editing = false
    @State private var changesPassword = false
    @State private var addsToken = false
    @State private var addsPermission = false
    @State private var confirmsDelete = false
    @State private var deletingToken: APIToken?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var user: AccessUser? { access.users?.first { $0.userid == userid } }
    private var canModify: Bool { access.can("User.Modify") }

    var body: some View {
        List {
            if let user {
                Section {
                    LabeledContent("Name", value: user.displayName ?? "–")
                    LabeledContent("Email", value: user.email ?? "–")
                    LabeledContent("Groups", value: user.groups.isEmpty ? "–" : user.groups.joined(separator: ", "))
                    LabeledContent("Realm", value: user.realm)
                    LabeledContent("Enabled", value: user.isEnabled ? String(localized: "Yes") : String(localized: "No"))
                    if let expires = user.expires {
                        LabeledContent("Expires", value: expires.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let comment = user.comment {
                        LabeledContent("Comment", value: comment)
                    }
                }
                Section {
                    Button("Edit", systemImage: "pencil") { editing = true }
                        .accessibilityIdentifier("user.edit")
                    if user.realmType == "pve" || user.realm == "pve" {
                        Button("Change Password", systemImage: "key") { changesPassword = true }
                            .accessibilityIdentifier("user.password")
                    }
                }
                .disabled(!canModify)
                PermissionList(access: access, entries: access.permissions(of: .user, userid), adding: $addsPermission)
                Section {
                    ForEach(user.tokens) { token in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(userid)!\(token.tokenid)")
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !token.isSeparated { Badge(text: "User's Privileges", color: .orange) }
                            }
                            let details = [token.comment, token.expires.map { String(localized: "Expires \($0.formatted(date: .abbreviated, time: .omitted))") }].compactMap { $0 }
                            if !details.isEmpty {
                                Text(details.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if canModify {
                                Button("Delete", systemImage: "trash") { deletingToken = token }
                                    .tint(.red)
                            }
                        }
                    }
                    Button("Add Token", systemImage: "plus") { addsToken = true }
                        .disabled(!canModify)
                        .accessibilityIdentifier("token.add")
                } header: {
                    Text("API Tokens")
                } footer: {
                    Text("Tokens let scripts and tools use the API without the password. With privilege separation, a token only has the permissions given to the token itself.")
                }
                if user.userid != "root@pam" {
                    Section {
                        Button("Delete User", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                            .disabled(!canModify)
                    }
                }
            }
        }
        .navigationTitle(userid)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            NavigationStack {
                if let user { UserEditor(access: access, user: user) }
            }
        }
        .sheet(isPresented: $changesPassword) {
            NavigationStack {
                PasswordView(access: access, userid: userid)
            }
        }
        .sheet(isPresented: $addsToken) {
            NavigationStack {
                TokenCreationView(access: access, userid: userid)
            }
        }
        .sheet(isPresented: $addsPermission) {
            NavigationStack {
                PermissionEditor(access: access, entry: ACLEntry(path: "/", subject: .user, subjectID: userid, role: ""))
            }
        }
        .confirmationDialog("Delete \(userid)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteUser() } }
        } message: {
            Text("The user, its API tokens and its permissions are removed.")
        }
        .confirmationDialog("Delete the token \(deletingToken?.tokenid ?? "")?", isPresented: Binding(get: { deletingToken != nil }, set: { if !$0 { deletingToken = nil } }), titleVisibility: .visible, presenting: deletingToken) { token in
            Button("Delete", role: .destructive) { Task { await deleteToken(token) } }
        } message: { _ in
            Text("Scripts using it stop working.")
        }
        .accessError($errorMessage)
    }

    private func deleteUser() async {
        do {
            try await access.deleteUser(userid)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteToken(_ token: APIToken) async {
        do {
            try await access.deleteToken(of: userid, tokenid: token.tokenid)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct UserEditor: View {
    let access: AccessControl
    let user: AccessUser?
    let original: UserDraft
    @State private var draft: UserDraft
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(access: AccessControl, user: AccessUser?) {
        self.access = access
        self.user = user
        let draft = user.map(UserDraft.init) ?? UserDraft()
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { user == nil }
    private var errors: [String: String] { (showsProblems ? draft.problems(isNew: isNew) : [:]).merging(fieldErrors) { _, server in server } }

    var body: some View {
        Form {
            Section {
                if isNew {
                    LabeledTextField(title: "User Name", prompt: "jane", text: $draft.name, identifier: "user.name")
                    Picker("Realm", selection: $draft.realm) {
                        ForEach(access.realms ?? [], id: \.realm) { realm in
                            Text(realm.comment.map { "\(realm.realm) – \($0)" } ?? realm.realm).tag(realm.realm)
                        }
                    }
                    FieldError(message: errors["userid"])
                } else {
                    LabeledContent("User", value: draft.userid)
                }
                Toggle("Enabled", isOn: $draft.isEnabled)
                Toggle("Expires", isOn: Binding(get: { draft.expires != nil }, set: { draft.expires = $0 ? Date().addingTimeInterval(86_400 * 30) : nil }))
                if let expires = draft.expires {
                    DatePicker("Expiry Date", selection: Binding(get: { expires }, set: { draft.expires = $0 }), in: Date()..., displayedComponents: .date)
                }
            } footer: {
                if isNew, draft.realm == "pam" {
                    Text("Linux PAM users must already exist on the nodes; their password is the system one.")
                }
            }
            if isNew, draft.realm == "pve" {
                Section("Password") {
                    // Another user's password: iOS must not offer a strong password or save it as one of the device
                    // owner's own. Without a content type it still guesses an account form; one-time code opts out.
                    SecureField("Password", text: $draft.password)
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("user.password.new")
                    SecureField("Confirm Password", text: $draft.passwordConfirmation)
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("user.password.confirm")
                    FieldError(message: errors["password"])
                }
            }
            Section("Details") {
                LabeledTextField(title: "First Name", prompt: "None", text: $draft.firstName)
                LabeledTextField(title: "Last Name", prompt: "None", text: $draft.lastName)
                LabeledTextField(title: "Email", prompt: "None", text: $draft.email, keyboard: .emailAddress)
                FieldError(message: errors["email"])
                LabeledTextField(title: "Comment", prompt: "None", text: $draft.comment)
            }
            if let groups = access.groups, !groups.isEmpty {
                Section("Groups") {
                    ForEach(groups) { group in
                        Toggle(isOn: Binding(get: { draft.groups.contains(group.groupid) }, set: { on in
                            if on { draft.groups.insert(group.groupid) } else { draft.groups.remove(group.groupid) }
                        })) {
                            Text(group.groupid)
                            if let comment = group.comment { Text(comment) }
                        }
                    }
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? "New User" : "Edit User")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                    .disabled(!isNew && draft.changes(from: original).isEmpty)
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func save() async {
        showsProblems = true
        fieldErrors = [:]
        guard draft.problems(isNew: isNew).isEmpty else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if isNew {
                try await access.createUser(draft)
            } else {
                try await access.updateUser(draft.userid, draft.changes(from: original))
            }
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PasswordView: View {
    let access: AccessControl
    let userid: String
    @State private var password = ""
    @State private var confirmation = ""
    @State private var ownPassword = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    private var problem: String? {
        if password.count < 8 { return String(localized: "Use at least 8 characters.") }
        if password != confirmation { return String(localized: "The passwords do not match.") }
        if access.needsPasswordConfirmation, ownPassword.isEmpty { return String(localized: "Enter your own current password.") }
        return nil
    }

    var body: some View {
        Form {
            Section {
                // Someone else's password, as in the user form.
                SecureField("New Password", text: $password)
                    .textContentType(.oneTimeCode)
                SecureField("Confirm Password", text: $confirmation)
                    .textContentType(.oneTimeCode)
                FieldError(message: fieldErrors["password"])
            } header: {
                Text("New Password for \(userid)")
            }
            if access.needsPasswordConfirmation {
                Section {
                    SecureField("Your Password", text: $ownPassword)
                        .textContentType(.password)
                    FieldError(message: fieldErrors["confirmation-password"])
                } footer: {
                    Text("Proxmox asks for the password of \(access.currentUser) to confirm the change.")
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
                    .disabled(problem != nil)
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { isSaving = false }
        do {
            try await access.changePassword(of: userid, to: password, confirmation: access.needsPasswordConfirmation ? ownPassword : nil)
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Creates a token and shows its secret once, with a copy button.
private struct TokenCreationView: View {
    let access: AccessControl
    let userid: String
    @State private var tokenid = ""
    @State private var comment = ""
    @State private var separated = true
    @State private var expires: Date?
    @State private var created: CreatedToken?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        guard let first = tokenid.first, first.isLetter, tokenid.count >= 2 else { return false }
        return tokenid.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }

    var body: some View {
        Form {
            if let created {
                Section {
                    LabeledContent("Token ID") { Text(created.fullID).font(.callout.monospaced()).textSelection(.enabled) }
                    LabeledContent("Secret") { Text(created.secret).font(.callout.monospaced()).textSelection(.enabled) }
                        .accessibilityIdentifier("token.secret")
                    Button("Copy Secret", systemImage: "doc.on.doc") { UIPasteboard.general.string = created.secret }
                } footer: {
                    Text("Store the secret now: Proxmox does not show it again. Use it as PVEAPIToken=\(created.fullID)=<secret>.")
                }
            } else {
                Section {
                    LabeledTextField(title: "Token ID", prompt: "monitoring", text: $tokenid, identifier: "token.id")
                    LabeledTextField(title: "Comment", prompt: "None", text: $comment)
                    Toggle("Privilege Separation", isOn: $separated)
                    Toggle("Expires", isOn: Binding(get: { expires != nil }, set: { expires = $0 ? Date().addingTimeInterval(86_400 * 365) : nil }))
                    if let date = expires {
                        DatePicker("Expiry Date", selection: Binding(get: { date }, set: { expires = $0 }), in: Date()..., displayedComponents: .date)
                    }
                } footer: {
                    Text(separated
                        ? "The token starts without permissions; add some under Permissions for \(userid)!\(tokenid.isEmpty ? "token" : tokenid)."
                        : "The token has all privileges of \(userid).")
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
                        .disabled(!isValid)
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
        errorMessage = nil
        defer { isSaving = false }
        do {
            created = try await access.createToken(for: userid, tokenid: tokenid, comment: comment, separated: separated, expires: expires)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Groups

private struct GroupsView: View {
    let access: AccessControl
    @State private var newGroup = ""
    @State private var newComment = ""
    @State private var creating = false
    @State private var deleting: AccessGroup?
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(access.groups ?? []) { group in
                NavigationLink {
                    GroupDetailView(access: access, groupid: group.groupid)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.groupid).font(.body.weight(.medium))
                        Text([group.comment, String(AttributedString(localized: "^[\(group.members.count) member](inflect: true)").characters)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("group.\(group.groupid)")
                .swipeActions {
                    if access.can("Group.Allocate") {
                        Button("Delete", systemImage: "trash") { deleting = group }
                            .tint(.red)
                    }
                }
            }
        }
        .overlay {
            if access.groups == nil {
                ProgressView()
            } else if access.groups?.isEmpty == true {
                ContentUnavailableView("No Groups", systemImage: "person.3", description: Text("Groups give the same permissions to several users."))
            }
        }
        .navigationTitle("Groups")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!access.can("Group.Allocate"))
                    .accessibilityIdentifier("group.add")
            }
        }
        .alert("New Group", isPresented: $creating) {
            TextField("Name", text: $newGroup)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Comment", text: $newComment)
            Button("Cancel", role: .cancel) { newGroup = ""; newComment = "" }
            Button("Add") { Task { await create() } }
        }
        .confirmationDialog("Delete the group \(deleting?.groupid ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { group in
            Button("Delete", role: .destructive) { Task { await delete(group) } }
        } message: { _ in
            Text("Members lose the permissions given to the group.")
        }
        .accessError($errorMessage)
    }

    private func create() async {
        let name = newGroup.trimmingCharacters(in: .whitespaces)
        defer { newGroup = ""; newComment = "" }
        guard !name.isEmpty else { return }
        do {
            try await access.createGroup(name, comment: newComment)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ group: AccessGroup) async {
        do {
            try await access.deleteGroup(group.groupid)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct GroupDetailView: View {
    let access: AccessControl
    let groupid: String
    @State private var comment = ""
    @State private var addsPermission = false
    @State private var errorMessage: String?

    private var group: AccessGroup? { access.groups?.first { $0.groupid == groupid } }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Comment", text: $comment, prompt: Text("Comment"))
                    if comment != (group?.comment ?? "") {
                        Button("Save") { Task { await saveComment() } }
                            .fontWeight(.semibold)
                    }
                }
            } header: {
                Text("Comment")
            }
            .disabled(!access.can("Group.Allocate"))
            Section {
                if group?.members.isEmpty ?? true {
                    Text("No members").foregroundStyle(.secondary)
                }
                ForEach(group?.members ?? [], id: \.self) { Text($0) }
            } header: {
                Text("Members")
            } footer: {
                Text("Add users to the group in their settings.")
            }
            PermissionList(access: access, entries: access.permissions(of: .group, groupid), adding: $addsPermission)
        }
        .navigationTitle(groupid)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { comment = group?.comment ?? "" }
        .sheet(isPresented: $addsPermission) {
            NavigationStack {
                PermissionEditor(access: access, entry: ACLEntry(path: "/", subject: .group, subjectID: groupid, role: ""))
            }
        }
        .accessError($errorMessage)
    }

    private func saveComment() async {
        do {
            try await access.updateGroup(groupid, comment: comment)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Roles

private struct RolesView: View {
    let access: AccessControl
    @State private var creating = false

    var body: some View {
        List {
            let roles = access.roles ?? []
            let custom = roles.filter { !$0.isBuiltIn }
            if !custom.isEmpty {
                Section("Custom") { ForEach(custom) { row($0) } }
            }
            Section("Built In") { ForEach(roles.filter(\.isBuiltIn)) { row($0) } }
        }
        .overlay { if access.roles == nil { ProgressView() } }
        .navigationTitle("Roles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!access.can("Sys.Modify"))
                    .accessibilityIdentifier("role.add")
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                RoleEditor(access: access, role: nil)
            }
        }
    }

    private func row(_ role: AccessRole) -> some View {
        NavigationLink {
            RoleEditor(access: access, role: role)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.roleid).font(.body.weight(.medium))
                Text(role.privileges.isEmpty ? String(localized: "No privileges") : String(AttributedString(localized: "^[\(role.privileges.count) privilege](inflect: true)").characters))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("role.\(role.roleid)")
    }
}

private struct RoleEditor: View {
    let access: AccessControl
    let role: AccessRole?
    @State private var roleid = ""
    @State private var privileges: Set<String>
    @State private var isSaving = false
    @State private var confirmsDelete = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(access: AccessControl, role: AccessRole?) {
        self.access = access
        self.role = role
        _privileges = State(initialValue: Set(role?.privileges ?? []))
    }

    private var isReadOnly: Bool { role?.isBuiltIn == true || !access.can("Sys.Modify") }

    var body: some View {
        Form {
            if role == nil {
                Section {
                    LabeledTextField(title: "Name", prompt: "Operator", text: $roleid, identifier: "role.name")
                }
            } else if role?.isBuiltIn == true {
                Section {
                    Label("Built-in roles cannot be changed. Create a custom role to combine privileges differently.", systemImage: "lock.fill")
                        .font(.subheadline)
                }
            }
            ForEach(AccessRole.privilegesByArea(access.roles ?? []), id: \.area) { area in
                Section(area.area) {
                    ForEach(area.privileges, id: \.self) { privilege in
                        Toggle(privilege, isOn: Binding(get: { privileges.contains(privilege) }, set: { on in
                            if on { privileges.insert(privilege) } else { privileges.remove(privilege) }
                        }))
                        .font(.callout.monospaced())
                        .accessibilityIdentifier("privilege.\(privilege)")
                    }
                }
            }
            .disabled(isReadOnly)
            if let role, !role.isBuiltIn, access.can("Sys.Modify") {
                Section {
                    Button("Delete Role", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(role?.roleid ?? String(localized: "New Role"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            if role == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if !isReadOnly {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(role == nil ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(role == nil ? roleid.trimmingCharacters(in: .whitespaces).isEmpty : privileges == Set(role?.privileges ?? []))
                        .accessibilityIdentifier("save")
                }
            }
        }
        .confirmationDialog("Delete \(role?.roleid ?? "")?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Permissions that use this role are removed too.")
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if let role {
                try await access.updateRole(role.roleid, privileges: privileges)
            } else {
                try await access.createRole(roleid.trimmingCharacters(in: .whitespaces), privileges: privileges)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() async {
        guard let role else { return }
        do {
            try await access.deleteRole(role.roleid)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Permissions

private struct PermissionsView: View {
    let access: AccessControl
    @State private var adding = false
    @State private var removing: ACLEntry?
    @State private var errorMessage: String?

    var body: some View {
        List {
            let byPath = Dictionary(grouping: access.acl ?? []) { $0.path }
            ForEach(byPath.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { path in
                Section(path) {
                    ForEach(byPath[path] ?? []) { entry in
                        PermissionRow(entry: entry, showsPath: false)
                            .swipeActions {
                                if access.can("Permissions.Modify") {
                                    Button("Remove", systemImage: "trash") { removing = entry }
                                        .tint(.red)
                                }
                            }
                    }
                }
            }
        }
        .overlay {
            if access.acl == nil {
                ProgressView()
            } else if access.acl?.isEmpty == true {
                ContentUnavailableView("No Permissions", systemImage: "lock.shield", description: Text("Only root@pam has access."))
            }
        }
        .navigationTitle("Permissions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { adding = true }
                    .disabled(!access.can("Permissions.Modify"))
                    .accessibilityIdentifier("permission.add")
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                PermissionEditor(access: access, entry: ACLEntry(path: "/", subject: .user, subjectID: "", role: ""))
            }
        }
        .confirmationDialog("Remove this permission?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { entry in
            Button("Remove", role: .destructive) { Task { await remove(entry) } }
        } message: { entry in
            Text("\(entry.subjectID) loses \(entry.role) on \(entry.path).")
        }
        .accessError($errorMessage)
    }

    private func remove(_ entry: ACLEntry) async {
        do {
            try await access.removePermission(entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PermissionRow: View {
    let entry: ACLEntry
    let showsPath: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.subject == .group ? "person.3" : entry.subject == .token ? "key.horizontal" : "person")
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(showsPath ? entry.path : entry.subjectID)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(entry.role)
                    if !entry.propagates { Badge(text: "This path only") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("permission.\(entry.path).\(entry.subjectID).\(entry.role)")
    }
}

/// The permissions given directly to one user or group, with Add and swipe to remove.
private struct PermissionList: View {
    let access: AccessControl
    let entries: [ACLEntry]
    @Binding var adding: Bool
    @State private var removing: ACLEntry?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            ForEach(entries) { entry in
                PermissionRow(entry: entry, showsPath: true)
                    .swipeActions {
                        if access.can("Permissions.Modify") {
                            Button("Remove", systemImage: "trash") { removing = entry }
                                .tint(.red)
                        }
                    }
            }
            Button("Add Permission", systemImage: "plus") { adding = true }
                .disabled(!access.can("Permissions.Modify"))
                .accessibilityIdentifier("permission.add")
        } header: {
            Text("Permissions")
        } footer: {
            Text("Only permissions given directly; those of groups apply as well.")
        }
        .confirmationDialog("Remove this permission?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { entry in
            Button("Remove", role: .destructive) {
                Task {
                    do { try await access.removePermission(entry) } catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .accessError($errorMessage)
    }
}

private struct PermissionEditor: View {
    let access: AccessControl
    @State private var entry: ACLEntry
    @State private var pools: [String] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    /// Opened from a user or group, the subject is fixed.
    private let fixedSubject: Bool

    init(access: AccessControl, entry: ACLEntry) {
        self.access = access
        _entry = State(initialValue: entry)
        fixedSubject = !entry.subjectID.isEmpty
    }

    private var subjects: [String] {
        switch entry.subject {
        case .user: (access.users ?? []).map(\.userid)
        case .group: (access.groups ?? []).map(\.groupid)
        case .token: (access.users ?? []).flatMap { user in user.tokens.map { "\(user.userid)!\($0.tokenid)" } }
        }
    }

    private var isValid: Bool { entry.path.hasPrefix("/") && !entry.subjectID.isEmpty && !entry.role.isEmpty }

    var body: some View {
        Form {
            Section {
                TextField("Path", text: $entry.path, prompt: Text("/vms/100"))
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("permission.path")
                Menu("Suggestions") {
                    ForEach(ACLEntry.suggestedPaths(snapshot: access.connection.snapshot, pools: pools), id: \.self) { path in
                        Button(path) { entry.path = path }
                    }
                }
                FieldError(message: fieldErrors["path"])
            } header: {
                Text("Path")
            } footer: {
                Text("/ is everything, /vms/100 one guest, /storage/local one storage, /pool/name the guests and storages of a pool.")
            }
            Section {
                if fixedSubject {
                    LabeledContent(entry.subject == .group ? "Group" : entry.subject == .token ? "Token" : "User", value: entry.subjectID)
                } else {
                    Picker("Type", selection: $entry.subject) {
                        Text("User").tag(ACLEntry.Subject.user)
                        Text("Group").tag(ACLEntry.Subject.group)
                        Text("API Token").tag(ACLEntry.Subject.token)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: entry.subject) { entry.subjectID = "" }
                    Picker(entry.subject == .group ? "Group" : entry.subject == .token ? "Token" : "User", selection: $entry.subjectID) {
                        Text("Choose").tag("")
                        ForEach(subjects, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("permission.subject")
                }
                Picker("Role", selection: $entry.role) {
                    Text("Choose").tag("")
                    ForEach(access.roles ?? []) { Text($0.roleid).tag($0.roleid) }
                }
                .accessibilityIdentifier("permission.role")
                Toggle("Propagate", isOn: $entry.propagates)
            } footer: {
                Text("Propagate applies the role to everything below the path as well.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Add Permission")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .task { pools = await access.connection.load(PVE.pools()).map(\.id) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Add", isWorking: isSaving) { Task { await save() } }
                    .disabled(!isValid)
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { isSaving = false }
        do {
            try await access.addPermission(entry)
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
