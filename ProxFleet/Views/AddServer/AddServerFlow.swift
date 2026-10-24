import FleetCore
import PBSKit
import ProxmoxCore
import PVEKit
import SwiftUI

extension ProxmoxProduct {
    var displayName: LocalizedStringKey {
        switch self {
        case .virtualEnvironment: "Proxmox VE"
        case .backupServer: "Proxmox Backup Server"
        }
    }
}

/// Sheet that walks through adding a server.
struct AddServerFlow: View {
    @Bindable var onboarding: ServerOnboarding
    var onFinish: (ServerProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if showsBackButton {
                            Button("Back", systemImage: "chevron.backward") { onboarding.goBack() }
                        } else {
                            Button("Cancel", systemImage: "xmark") { dismiss() }
                        }
                    }
                }
                .animation(.default, value: onboarding.step)
        }
        .interactiveDismissDisabled(onboarding.isWorking)
        .onChange(of: onboarding.step) {
            if case .finished(let profile) = onboarding.step {
                onFinish(profile)
                dismiss()
            }
        }
    }

    private var secondFactorChallenge: SecondFactorChallenge? {
        if case .secondFactor(let challenge) = onboarding.step { challenge } else { nil }
    }

    private var showsBackButton: Bool {
        switch onboarding.step {
        case .address, .finished: false
        default: true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch onboarding.step {
        case .address, .finished:
            AddressStep(onboarding: onboarding)
        case .certificate(let certificate):
            CertificateTrustView(certificate: certificate, host: onboarding.addressText, previouslyTrusted: false, isWorking: onboarding.isWorking) {
                Task { await onboarding.trustCertificate(certificate) }
            }
        case .credentials, .secondFactor:
            PasswordThenSecondFactor(challenge: secondFactorChallenge) {
                CredentialsStep(onboarding: onboarding, isCovered: secondFactorChallenge != nil)
            } codeForm: { challenge in
                SecondFactorForm(challenge: challenge, isWorking: onboarding.isWorking, errorMessage: onboarding.errorMessage) { method, code in
                    Task { await onboarding.submitSecondFactor(challenge, method: method, code: code) }
                }
            }
        case .unsupportedRelease(let version):
            UnsupportedReleaseStep(onboarding: onboarding, version: version)
        case .duplicateCluster(let existing):
            DuplicateClusterStep(onboarding: onboarding, existing: existing)
        }
    }
}

private struct AddressStep: View {
    @Bindable var onboarding: ServerOnboarding
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                Picker("Server", selection: $onboarding.product) {
                    Text("Proxmox VE").tag(ProxmoxProduct.virtualEnvironment)
                    Text("Backup Server").tag(ProxmoxProduct.backupServer)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("product")
            }
            Section {
                TextField("Host or IP address", text: $onboarding.addressText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.continue)
                    .onSubmit(submit)
                    .accessibilityIdentifier("address")
            } footer: {
                switch onboarding.product {
                case .virtualEnvironment:
                    Text("For example 192.168.1.10 or pve.home.lan. Port 8006 is used unless you add another, like pve.lan:443. For a cluster, any node works.")
                case .backupServer:
                    Text("For example 192.168.1.20 or pbs.home.lan. Port 8007 is used unless you add another, like pbs.lan:443.")
                }
            }
            ErrorSection(message: onboarding.errorMessage)
        }
        .navigationTitle("Add Server")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Continue", isWorking: onboarding.isWorking, action: submit)
                    .disabled(!onboarding.canSubmitAddress)
                    .accessibilityIdentifier("continue")
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard onboarding.canSubmitAddress, !onboarding.isWorking else { return }
        Task { await onboarding.submitAddress() }
    }
}

private struct CredentialsStep: View {
    @Bindable var onboarding: ServerOnboarding
    /// The second-factor form shows over this one, which then leaves the title and toolbar to it.
    let isCovered: Bool
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    var body: some View {
        Form {
            Section {
                TextField("User name", text: $onboarding.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .accessibilityIdentifier("username")
                SecureField("Password", text: $onboarding.password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .accessibilityIdentifier("password")
                if !onboarding.realms.isEmpty {
                    RealmMenu(realms: onboarding.realms, selection: $onboarding.realm)
                }
            } header: {
                Text(onboarding.addressText)
            }
            if onboarding.switchedProduct {
                Section {
                    Label {
                        switch onboarding.product {
                        case .virtualEnvironment: Text("This address belongs to a Proxmox VE server.")
                        case .backupServer: Text("This address belongs to a Proxmox Backup Server.")
                        }
                    } icon: {
                        Image(systemName: onboarding.product == .backupServer ? "externaldrive.badge.timemachine" : "server.rack")
                            .foregroundStyle(.tint)
                    }
                    .accessibilityIdentifier("switchedProduct")
                }
            }
            Section {
                Toggle("Remember Password", isOn: $onboarding.rememberPassword)
            } footer: {
                Text("Stored in the Keychain on this device only, so you are not asked again when the session expires.")
            }
            ErrorSection(message: onboarding.errorMessage)
        }
        .navigationTitle(isCovered ? "Two-Factor Authentication" : onboarding.product == .backupServer ? "Sign In to Backup Server" : "Sign In")
        .toolbar {
            if !isCovered {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton("Sign In", isWorking: onboarding.isWorking, action: submit)
                        .disabled(!onboarding.canSignIn)
                        .accessibilityIdentifier("signIn")
                }
            }
        }
        .onAppear { focusedField = onboarding.username.isEmpty ? .username : .password }
    }

    private func submit() {
        guard onboarding.canSignIn, !onboarding.isWorking else { return }
        Task { await onboarding.signIn() }
    }
}

/// The realm as a menu row: its short ID in the row, the description as a subtitle in the menu.
/// A menu picker would show only the first line of each choice, so each realm is a toggle, which iOS shows with a
/// check mark and its second text as the subtitle.
private struct RealmMenu: View {
    let realms: [Realm]
    @Binding var selection: String

    var body: some View {
        LabeledContent("Realm") {
            Menu {
                ForEach(realms) { realm in
                    Toggle(isOn: Binding(get: { selection == realm.realm }, set: { if $0 { selection = realm.realm } })) {
                        Text(realm.realm)
                        if let comment = realm.comment, !comment.isEmpty {
                            Text(comment)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.medium))
                }
            }
            // Gray like a picker's value, not the accent color of a menu.
            .tint(.secondary)
            .accessibilityIdentifier("realm")
        }
    }
}

private struct UnsupportedReleaseStep: View {
    let onboarding: ServerOnboarding
    let version: String

    var body: some View {
        Form {
            Section {
                Label {
                    switch onboarding.product {
                    case .virtualEnvironment:
                        Text("This server runs Proxmox VE \(version), which ProxFleet does not officially support. Some features may not work correctly.")
                    case .backupServer:
                        Text("This server runs Proxmox Backup Server \(version), which ProxFleet does not officially support. Some features may not work correctly.")
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } footer: {
                switch onboarding.product {
                case .virtualEnvironment:
                    Text("ProxFleet supports Proxmox VE \(String(PVEVersionNumber.oldestSupported.major)) and newer.")
                case .backupServer:
                    Text("ProxFleet supports Proxmox Backup Server \(String(PBSVersion.oldestSupported.major)) and newer.")
                }
            }
            Section {
                Button("Add Anyway") { onboarding.addUnsupportedRelease() }
                    .accessibilityIdentifier("addUnsupportedRelease")
            }
        }
        .navigationTitle("Unsupported Version")
    }
}

private struct DuplicateClusterStep: View {
    let onboarding: ServerOnboarding
    let existing: ServerProfile

    var body: some View {
        Form {
            Section {
                Label {
                    Text("This node belongs to the cluster **\(existing.clusterName ?? existing.name)**, which is already saved as “\(existing.name)”.")
                } icon: {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(.tint)
                }
            } footer: {
                Text("Adding the address to the saved cluster lets the app switch to this node when the other one is unreachable.")
            }
            Section {
                Button("Add Address to “\(existing.name)”") { onboarding.mergeIntoExisting(existing) }
                Button("Add as Separate Server") { onboarding.addSeparately() }
            }
        }
        .navigationTitle("Cluster Already Saved")
    }
}
