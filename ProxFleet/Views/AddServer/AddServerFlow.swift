import FleetCore
import ProxmoxCore
import SwiftUI

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
        case .credentials:
            CredentialsStep(onboarding: onboarding)
        case .secondFactor(let challenge):
            SecondFactorForm(challenge: challenge, isWorking: onboarding.isWorking, errorMessage: onboarding.errorMessage) { method, code in
                Task { await onboarding.submitSecondFactor(challenge, method: method, code: code) }
            }
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
                Text("For example 192.168.1.10 or pve.home.lan. Port 8006 is used unless you add another, like pve.lan:443. For a cluster, any node works.")
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
                    Picker("Realm", selection: $onboarding.realm) {
                        ForEach(onboarding.realms) { realm in
                            // Short ID in the row, the description as a subtitle in the menu.
                            VStack {
                                Text(realm.realm)
                                if let comment = realm.comment {
                                    Text(comment)
                                }
                            }
                            .tag(realm.realm)
                        }
                    }
                    .accessibilityIdentifier("realm")
                }
            } header: {
                Text(onboarding.addressText)
            }
            Section {
                Toggle("Remember Password", isOn: $onboarding.rememberPassword)
            } footer: {
                Text("Stored in the Keychain on this device only, so you are not asked again when the session expires.")
            }
            ErrorSection(message: onboarding.errorMessage)
        }
        .navigationTitle("Sign In")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Sign In", isWorking: onboarding.isWorking, action: submit)
                    .disabled(!onboarding.canSignIn)
                    .accessibilityIdentifier("signIn")
            }
        }
        .onAppear { focusedField = onboarding.username.isEmpty ? .username : .password }
    }

    private func submit() {
        guard onboarding.canSignIn, !onboarding.isWorking else { return }
        Task { await onboarding.signIn() }
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
