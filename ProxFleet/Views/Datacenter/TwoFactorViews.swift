import CoreImage.CIFilterBuiltins
import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Second factors of every user, or of one user: authenticator apps, recovery keys and security keys.
struct TwoFactorListView: View {
    let access: AccessControl
    /// nil lists every user the signed-in user may see.
    var userid: String?
    @State private var adding: TwoFactorAddition?
    @State private var editing: EditedEntry?
    @State private var deleting: EditedEntry?
    @State private var password = ""
    @State private var errorMessage: String?

    private var users: [UserTwoFactors] {
        let all = access.twoFactors ?? []
        guard let userid else { return all.filter { !$0.entries.isEmpty || $0.isLocked() } }
        return all.filter { $0.userid == userid }
    }

    var body: some View {
        List {
            ForEach(users) { factors in
                Section {
                    if factors.isLocked() {
                        LockedRow(factors: factors, canUnlock: access.can("User.Modify")) {
                            Task { await unlock(factors.userid) }
                        }
                    }
                    ForEach(factors.entries) { entry in
                        Button {
                            editing = EditedEntry(userid: factors.userid, entry: entry)
                        } label: {
                            TwoFactorRow(entry: entry)
                        }
                        .foregroundStyle(.primary)
                        .disabled(!canModify(factors.userid))
                        .accessibilityIdentifier("tfa.\(factors.userid).\(entry.id)")
                        .swipeActions {
                            if canModify(factors.userid) {
                                Button("Delete", systemImage: "trash") { deleting = EditedEntry(userid: factors.userid, entry: entry) }
                                    .tint(.red)
                            }
                        }
                    }
                    if factors.entries.isEmpty {
                        Text("No second factors.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    if userid == nil { Text(verbatim: factors.userid) }
                }
            }
            Section {
            } footer: {
                Text("A second factor asks for a code after the password. Users can add their own; others need the User.Modify privilege. Add WebAuthn security keys in the web interface.")
            }
        }
        .overlay {
            if access.twoFactors == nil {
                ProgressView()
            } else if users.isEmpty {
                ContentUnavailableView("No Second Factors", systemImage: "lock.rotation", description: Text("Nobody has added an authenticator app or recovery keys yet."))
            }
        }
        .navigationTitle("Two-Factor Authentication")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("Authenticator App", systemImage: "clock.arrow.circlepath") { adding = .totp }
                        .accessibilityIdentifier("tfa.add.totp")
                    Button("Recovery Keys", systemImage: "list.number") { adding = .recovery }
                        .disabled(userid.flatMap { access.twoFactors(of: $0) }?.hasRecoveryKeys ?? false)
                        .accessibilityIdentifier("tfa.add.recovery")
                }
                .disabled(userid.map { !canModify($0) } ?? false)
                .accessibilityIdentifier("tfa.add")
            }
        }
        .refreshable { await access.load() }
        .task { if access.twoFactors == nil { await access.load() } }
        .sheet(item: $adding) { addition in
            NavigationStack {
                switch addition {
                case .totp: AddTOTPView(access: access, userid: userid)
                case .recovery: RecoveryKeysView(access: access, userid: userid)
                }
            }
        }
        .sheet(item: $editing) { edited in
            NavigationStack {
                TwoFactorEntryEditor(access: access, edited: edited)
            }
        }
        .alert("Delete \(deleting?.entry.title ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { deleted in
            if access.needsPasswordConfirmation {
                SecureField("Your Password", text: $password)
                    .textContentType(.oneTimeCode)
            }
            Button("Cancel", role: .cancel) { password = "" }
            Button("Delete", role: .destructive) { Task { await delete(deleted) } }
                .accessibilityIdentifier("tfa.delete.confirm")
        } message: { deleted in
            Text(deleted.entry.type == "recovery"
                 ? "The remaining recovery keys stop working."
                 : "\(deleted.userid) can no longer sign in with it.")
        }
        .accessError($errorMessage)
    }

    /// Everyone may change their own second factors.
    private func canModify(_ userid: String) -> Bool {
        userid == access.currentUser || access.can("User.Modify")
    }

    private func delete(_ deleted: EditedEntry) async {
        defer { password = "" }
        do {
            try await access.deleteTwoFactor(of: deleted.userid, id: deleted.entry.id, password: access.needsPasswordConfirmation ? password : nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlock(_ userid: String) async {
        do {
            try await access.unlockTwoFactor(of: userid)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum TwoFactorAddition: String, Identifiable {
    case totp, recovery
    var id: String { rawValue }
}

private struct EditedEntry: Identifiable {
    let userid: String
    let entry: TwoFactorEntry
    var id: String { "\(userid)/\(entry.id)" }
}

extension TwoFactorEntry {
    var title: String {
        if !description.isEmpty, type != "recovery" { return description }
        return typeTitle
    }

    var typeTitle: String {
        switch type {
        case "totp": String(localized: "Authenticator App")
        case "recovery": String(localized: "Recovery Keys")
        case "webauthn": String(localized: "WebAuthn Security Key")
        case "u2f": String(localized: "U2F Security Key")
        case "yubico": String(localized: "Yubico OTP")
        default: type
        }
    }

    var systemImage: String {
        switch type {
        case "totp": "clock.arrow.circlepath"
        case "recovery": "list.number"
        default: "key.horizontal"
        }
    }
}

private struct TwoFactorRow: View {
    let entry: TwoFactorEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.systemImage)
                .font(.title3)
                .foregroundStyle(entry.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .lineLimit(1)
                    if !entry.isEnabled { AccessBadge(text: "Disabled") }
                }
                let details = [entry.title == entry.typeTitle ? nil : entry.typeTitle,
                               entry.created.map { String(localized: "Added \($0.formatted(date: .abbreviated, time: .omitted))") }].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LockedRow: View {
    let factors: UserTwoFactors
    let canUnlock: Bool
    let onUnlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                if factors.isTOTPLocked {
                    Text("Authenticator codes are locked after too many wrong codes.")
                } else if let until = factors.lockedUntil {
                    Text("Second factors are locked after too many failed attempts, until \(until.formatted(date: .omitted, time: .shortened)).")
                }
            } icon: {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
            }
            .font(.subheadline)
            if canUnlock {
                Button("Unlock", action: onUnlock)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("tfa.unlock.\(factors.userid)")
            }
        }
    }
}

// The "Your Password" fields use the one-time-code content type: as `.password`, iOS would offer to save the
// confirmation as a new password once the sheet closes.

/// Picks the user a second factor is for: the signed-in user, or anyone with User.Modify.
private struct TwoFactorUserPicker: View {
    let access: AccessControl
    @Binding var selection: String

    var body: some View {
        if access.can("User.Modify"), let users = access.users, users.count > 1 {
            Picker("User", selection: $selection) {
                if !users.contains(where: { $0.userid == selection }) {
                    Text(verbatim: selection).tag(selection)
                }
                ForEach(users) { Text(verbatim: $0.userid).tag($0.userid) }
            }
        } else {
            LabeledContent("User", value: selection)
        }
    }
}

private extension AccessControl {
    /// The user a new second factor is for when the list does not say: the signed-in user, or, when they are not
    /// a user of the datacenter (such as the demo account), root@pam, which every server has.
    func twoFactorUser(_ preferred: String?) -> String {
        if let preferred { return preferred }
        guard let users, !users.contains(where: { $0.userid == currentUser }), can("User.Modify") else { return currentUser }
        return users.first { $0.userid == "root@pam" }?.userid ?? users.first?.userid ?? currentUser
    }
}

/// Sets up an authenticator app: a secret made on the device, shown as a QR code, confirmed by a current code.
private struct AddTOTPView: View {
    let access: AccessControl
    @State private var userid: String
    @State private var secret: TOTPSecret
    @State private var description = String(localized: "Authenticator App")
    @State private var code = ""
    @State private var password = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    init(access: AccessControl, userid: String?) {
        self.access = access
        let userid = access.twoFactorUser(userid)
        _userid = State(initialValue: userid)
        _secret = State(initialValue: TOTPSecret.random(issuer: "Proxmox - \(access.connection.currentAddress.host)", account: userid))
    }

    private var canSave: Bool {
        code.filter(\.isNumber).count == TOTPSecret.digits && (!access.needsPasswordConfirmation || !password.isEmpty)
    }

    var body: some View {
        Form {
            Section {
                TwoFactorUserPicker(access: access, selection: $userid)
                LabeledTextField(title: "Description", prompt: "Phone", text: $description, identifier: "tfa.description")
            }
            Section {
                if let image = QRCode.image(for: secret.uri) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(.white, in: .rect(cornerRadius: 12))
                        .accessibilityLabel("QR code for the authenticator app")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Secret")
                    Text(secret.grouped)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("tfa.secret")
                }
                Button(copied ? "Copied" : "Copy Secret", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = secret.secret
                    copied = true
                }
                if let url = URL(string: secret.uri) {
                    Link(destination: url) {
                        Label("Add to an App on This iPhone", systemImage: "arrow.up.forward.app")
                    }
                }
            } header: {
                Text("Authenticator App")
            } footer: {
                Text("Scan the code with an authenticator app, or enter the secret. On this iPhone, the Passwords app can keep the codes too.")
            }
            Section {
                TextField("6-digit code", text: $code)
                    .font(.title3.monospaced())
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("tfa.code")
                if access.needsPasswordConfirmation {
                    SecureField("Your Password", text: $password)
                        .textContentType(.oneTimeCode)
                }
            } header: {
                Text("Confirm")
            } footer: {
                Text(access.needsPasswordConfirmation
                     ? "Enter the code the app shows now, and your own password to confirm the change."
                     : "Enter the code the app shows now.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Authenticator App")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .onChange(of: userid) {
            secret = TOTPSecret.random(issuer: secret.issuer, account: userid)
            code = ""
            copied = false
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Add", isWorking: isSaving) { Task { await save() } }
                    .disabled(!canSave)
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await access.addTOTP(for: userid, secret: secret, code: code, description: description,
                                     password: access.needsPasswordConfirmation ? password : nil)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Creates recovery keys and shows them once.
private struct RecoveryKeysView: View {
    let access: AccessControl
    @State private var userid: String
    @State private var password = ""
    @State private var keys: [String] = []
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    init(access: AccessControl, userid: String?) {
        self.access = access
        _userid = State(initialValue: access.twoFactorUser(userid))
    }

    private var hasKeys: Bool { access.twoFactors(of: userid)?.hasRecoveryKeys ?? false }

    var body: some View {
        Form {
            if keys.isEmpty {
                Section {
                    TwoFactorUserPicker(access: access, selection: $userid)
                    if access.needsPasswordConfirmation {
                        SecureField("Your Password", text: $password)
                            .textContentType(.oneTimeCode)
                    }
                } footer: {
                    if hasKeys {
                        Text("\(userid) already has recovery keys. Delete them first to create new ones.")
                    } else {
                        Text("Recovery keys let \(userid) sign in when the authenticator app is lost. Each key works once.")
                    }
                }
                Section {
                    Button("Create Recovery Keys") { Task { await create() } }
                        .disabled(hasKeys || isWorking || (access.needsPasswordConfirmation && password.isEmpty))
                        .accessibilityIdentifier("tfa.recovery.create")
                }
            } else {
                Section {
                    ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                        LabeledContent {
                            Text(key)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        } label: {
                            Text(verbatim: "\(index + 1)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Recovery Keys")
                } footer: {
                    Text("Store them somewhere safe now: they are not shown again.")
                }
                .accessibilityIdentifier("tfa.recovery.keys")
                Section {
                    Button(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = keysText
                        copied = true
                    }
                    ShareLink(item: keysText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Recovery Keys")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isWorking || !keys.isEmpty)
        .toolbar {
            if keys.isEmpty {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("done")
                }
            }
        }
    }

    private var keysText: String {
        (["Proxmox recovery keys for \(userid) (\(access.connection.currentAddress.host))"] + keys).joined(separator: "\n")
    }

    private func create() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            keys = try await access.addRecoveryKeys(for: userid, password: access.needsPasswordConfirmation ? password : nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Renames a second factor, or turns it off without removing it.
private struct TwoFactorEntryEditor: View {
    let access: AccessControl
    let edited: EditedEntry
    @State private var description: String
    @State private var isEnabled: Bool
    @State private var password = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(access: AccessControl, edited: EditedEntry) {
        self.access = access
        self.edited = edited
        _description = State(initialValue: edited.entry.description)
        _isEnabled = State(initialValue: edited.entry.isEnabled)
    }

    private var hasChanges: Bool { description != edited.entry.description || isEnabled != edited.entry.isEnabled }

    var body: some View {
        Form {
            Section {
                LabeledContent("User", value: edited.userid)
                LabeledContent("Type", value: edited.entry.typeTitle)
                if let created = edited.entry.created {
                    LabeledContent("Added", value: created.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section {
                LabeledTextField(title: "Description", prompt: "None", text: $description)
                Toggle("Enabled", isOn: $isEnabled)
                    .accessibilityIdentifier("tfa.enabled")
            } footer: {
                Text("A disabled second factor stays configured but cannot be used to sign in.")
            }
            if access.needsPasswordConfirmation {
                Section {
                    SecureField("Your Password", text: $password)
                        .textContentType(.oneTimeCode)
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(edited.entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Save", isWorking: isSaving) { Task { await save() } }
                    .disabled(!hasChanges || (access.needsPasswordConfirmation && password.isEmpty))
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await access.updateTwoFactor(of: edited.userid, id: edited.entry.id, description: description, isEnabled: isEnabled,
                                             password: access.needsPasswordConfirmation ? password : nil)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum QRCode {
    /// A sharp QR code image; scale it with `.interpolation(.none)`.
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
