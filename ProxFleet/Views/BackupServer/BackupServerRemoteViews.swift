import FleetCore
import PBSKit
import SwiftUI

/// Other backup servers that sync jobs pull from or push to.
struct BackupServerRemotesView: View {
    @State private var remotes: BackupServerRemotes
    @State private var creating = false
    @State private var deleting: BackupRemote?
    @State private var errorMessage: String?

    init(connection: ServerConnection) {
        _remotes = State(initialValue: BackupServerRemotes(connection: connection))
    }

    var body: some View {
        List {
            if let list = remotes.remotes {
                Section {
                    ForEach(list) { remote in
                        NavigationLink {
                            RemoteEditor(remotes: remotes, remote: remote)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(remote.name)
                                    .font(.body.weight(.medium))
                                Text("\(remote.authID) · \(remote.address)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let comment = remote.comment {
                                    Text(comment)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .accessibilityIdentifier("remote.\(remote.name)")
                        .swipeActions {
                            if remotes.canModify {
                                Button("Delete", systemImage: "trash") { deleting = remote }
                                    .tint(.red)
                            }
                        }
                    }
                } footer: {
                    if !list.isEmpty {
                        Text("Sync jobs sign in to a remote with its user or API token, and see what its permissions allow there.")
                    }
                }
            }
        }
        .navigationTitle("Remotes")
        .overlay {
            if let error = remotes.loadError, remotes.remotes == nil {
                ContentUnavailableView("Cannot Load Remotes", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if remotes.remotes == nil {
                ProgressView()
            } else if remotes.remotes?.isEmpty == true {
                ContentUnavailableView("No Remotes", systemImage: "server.rack",
                                       description: Text("Add another Proxmox Backup Server to pull backups from it, or push them to it."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!remotes.canModify)
                    .accessibilityIdentifier("remote.add")
            }
        }
        .refreshable { await remotes.load() }
        .task { await remotes.load() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                RemoteEditor(remotes: remotes, remote: nil)
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { remote in
            Button("Delete Remote", role: .destructive) {
                Task {
                    do {
                        try await remotes.delete(remote.name)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } message: { _ in
            Text("Sync jobs that use the remote stop working.")
        }
        .alert("Cannot Delete the Remote", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

struct RemoteEditor: View {
    let remotes: BackupServerRemotes
    let remote: BackupRemote?
    private let original: RemoteDraft
    @State private var draft: RemoteDraft
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @State private var check: Result<[DatastoreSummary], ConfigUpdateError>?
    @State private var isChecking = false
    @Environment(\.dismiss) private var dismiss

    init(remotes: BackupServerRemotes, remote: BackupRemote?) {
        self.remotes = remotes
        self.remote = remote
        original = remote.map(RemoteDraft.init) ?? RemoteDraft()
        _draft = State(initialValue: original)
    }

    private var isNew: Bool { remote == nil }

    private var errors: [String: String] {
        (showsProblems ? draft.problems(isNew: isNew) : [:]).merging(fieldErrors) { _, server in server }
    }

    private var hasChanges: Bool { !draft.update(from: original, digest: nil).isEmpty }

    var body: some View {
        Form {
            if !remotes.canModify {
                Section {
                    Label(missingPrivilegeMessage("Remote.Modify", on: "/remote"), systemImage: "lock.fill")
                        .font(.subheadline)
                }
            }
            Group {
                Section {
                    if isNew {
                        LabeledTextField(title: "Remote ID", prompt: "offsite", text: $draft.name, identifier: "remote.name")
                        FieldError(message: errors["name"])
                    }
                    LabeledTextField(title: "Host", prompt: "pbs.example.com", text: $draft.address, keyboard: .URL, identifier: "remote.host")
                    FieldError(message: errors["host"] ?? errors["port"])
                    LabeledTextField(title: "Auth ID", prompt: "sync@pbs", text: $draft.authID, identifier: "remote.authid")
                    FieldError(message: errors["auth-id"])
                    LabeledContent(isNew ? "Password" : "New Password") {
                        SecureField(isNew ? "Password" : "New Password", text: $draft.password, prompt: Text(isNew ? "Required" : "Unchanged"))
                            .multilineTextAlignment(.trailing)
                            .textContentType(.password)
                            .accessibilityIdentifier("remote.password")
                    }
                    FieldError(message: errors["password"])
                } footer: {
                    Text("Add a port after the host when it is not 8007. For an API token, enter the token ID (user@realm!name) and its secret as the password.")
                }
                Section {
                    TextField("Fingerprint", text: $draft.fingerprint, prompt: Text("Not needed for trusted certificates"), axis: .vertical)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("remote.fingerprint")
                    FieldError(message: errors["fingerprint"])
                } header: {
                    Text("Fingerprint")
                } footer: {
                    Text("The SHA-256 fingerprint of the remote's certificate, shown on its dashboard. Needed when the certificate is self-signed.")
                }
                Section {
                    LabeledContent("Comment") {
                        TextField("Comment", text: $draft.comment, prompt: Text("None"))
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("remote.comment")
                    }
                    if remotes.connection.supports(backupServer: .remoteProxy) {
                        Toggle("Use Node Proxy", isOn: $draft.usesNodeProxy)
                    }
                } footer: {
                    if remotes.connection.supports(backupServer: .remoteProxy) {
                        Text("Connects through the HTTP proxy set in the server's options.")
                    }
                }
            }
            .disabled(!remotes.canModify)
            if let remote {
                Section {
                    Button {
                        Task {
                            isChecking = true
                            check = await remotes.check(remote.name)
                            isChecking = false
                        }
                    } label: {
                        HStack {
                            Label("Check Connection", systemImage: "network")
                            if isChecking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isChecking)
                    .accessibilityIdentifier("remote.check")
                    switch check {
                    case .success(let stores):
                        Label(stores.isEmpty ? String(localized: "Connected. The remote's user sees no datastores.")
                                : String(localized: "Connected. Datastores: \(stores.map(\.store).joined(separator: ", "))"),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    case .failure(let error):
                        Label(error.localizedDescription, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    case nil:
                        EmptyView()
                    }
                } footer: {
                    Text("Signs in with the saved settings and lists the datastores the remote's user can see.")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(remote?.name ?? String(localized: "New Remote"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if remotes.canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!isNew && !hasChanges)
                        .accessibilityIdentifier("save")
                }
            }
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
            if let remote {
                try await remotes.update(remote.name, draft.update(from: original, digest: nil))
            } else {
                try await remotes.create(draft)
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
