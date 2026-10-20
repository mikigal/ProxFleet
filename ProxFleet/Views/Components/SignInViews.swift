import ProxmoxCore
import SwiftUI

/// Shows a certificate that is not publicly trusted and lets the user accept it.
struct CertificateTrustView: View {
    let certificate: CertificateDetails
    let host: String
    let previouslyTrusted: Bool
    let isWorking: Bool
    let onTrust: () -> Void

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(previouslyTrusted ? "Certificate Changed" : "Unverified Certificate")
                            .font(.headline)
                        Text(previouslyTrusted
                             ? "\(host) presents a different certificate than the one you trusted before. This is expected after renewing the certificate. If you did not change it, someone may be intercepting the connection."
                             : "\(host) uses a self-signed certificate. This is normal for Proxmox, but make sure the fingerprint below matches your server before continuing.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: previouslyTrusted ? "exclamationmark.shield.fill" : "lock.trianglebadge.exclamationmark.fill")
                        .foregroundStyle(previouslyTrusted ? .red : .orange)
                        .font(.title2)
                }
            }
            Section("SHA-256 Fingerprint") {
                Text(certificate.sha256Fingerprint)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("fingerprint")
            }
            Section("Certificate") {
                if let subject = certificate.subject {
                    LabeledContent("Subject", value: subject)
                }
                if let date = certificate.notValidBefore {
                    LabeledContent("Valid From", value: date.formatted(date: .abbreviated, time: .omitted))
                }
                if let date = certificate.notValidAfter {
                    LabeledContent("Valid Until", value: date.formatted(date: .abbreviated, time: .omitted))
                }
            }
            Section {
                Button(action: onTrust) {
                    HStack {
                        Text("Trust This Certificate")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(isWorking)
                .accessibilityIdentifier("trustCertificate")
            } footer: {
                Text("In the Proxmox web interface, the fingerprint is shown under the node’s System → Certificates.")
            }
        }
        .navigationTitle("Certificate")
    }
}

/// Code entry for TOTP, Yubico OTP or a recovery key.
struct SecondFactorForm: View {
    let challenge: SecondFactorChallenge
    let isWorking: Bool
    let errorMessage: String?
    let onSubmit: (SecondFactorMethod, String) -> Void

    @State private var method: SecondFactorMethod
    @State private var code = ""
    @FocusState private var focused: Bool

    init(challenge: SecondFactorChallenge, isWorking: Bool, errorMessage: String?, onSubmit: @escaping (SecondFactorMethod, String) -> Void) {
        self.challenge = challenge
        self.isWorking = isWorking
        self.errorMessage = errorMessage
        self.onSubmit = onSubmit
        _method = State(initialValue: challenge.supportedMethods.first ?? .totp)
    }

    var body: some View {
        Form {
            if challenge.supportedMethods.isEmpty {
                ContentUnavailableView(
                    "Security Key Required",
                    systemImage: "key.slash",
                    description: Text("This account only allows WebAuthn or U2F security keys, which the app does not support yet. Add a TOTP authenticator or recovery keys to the account in the web interface.")
                )
            } else {
                if challenge.supportedMethods.count > 1 {
                    Section {
                        Picker("Method", selection: $method) {
                            ForEach(challenge.supportedMethods) { method in
                                Text(method.title).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }
                Section {
                    TextField(method.placeholder, text: $code)
                        .font(.title3.monospaced())
                        .textContentType(method == .totp ? .oneTimeCode : nil)
                        .keyboardType(method == .totp ? .numberPad : .asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit(submit)
                        .accessibilityIdentifier("secondFactorCode")
                } footer: {
                    Text(method.explanation)
                }
                ErrorSection(message: errorMessage)
                Section {
                    Button(action: submit) {
                        HStack {
                            Text("Verify")
                            Spacer()
                            if isWorking { ProgressView() }
                        }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    .accessibilityIdentifier("verify")
                }
            }
        }
        .navigationTitle("Two-Factor Authentication")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
        .onChange(of: method) { code = "" }
    }

    private func submit() {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isWorking else { return }
        onSubmit(method, trimmed)
    }
}

extension SecondFactorMethod {
    var title: LocalizedStringKey {
        switch self {
        case .totp: "Authenticator"
        case .yubico: "YubiKey OTP"
        case .recovery: "Recovery Key"
        }
    }

    var placeholder: LocalizedStringKey {
        switch self {
        case .totp: "6-digit code"
        case .yubico: "Touch your YubiKey"
        case .recovery: "Recovery key"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .totp: "Enter the code from your authenticator app."
        case .yubico: "Focus the field and touch your YubiKey to enter a one-time password."
        case .recovery: "Each recovery key works only once."
        }
    }
}

/// Password prompt for a saved server whose password is not stored or was rejected.
struct PasswordPrompt: View {
    let userID: String
    let message: String?
    let onSubmit: (String, Bool) -> Void

    @State private var password = ""
    @State private var remember = true
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                LabeledContent("User", value: userID)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .accessibilityIdentifier("password")
            } footer: {
                if let message { Text(message) }
            }
            Section {
                Toggle("Remember Password", isOn: $remember)
            }
            Section {
                Button("Sign In", action: submit)
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("signIn")
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        onSubmit(password, remember)
        password = ""
    }
}

struct ErrorSection: View {
    let message: String?

    var body: some View {
        if let message {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("errorMessage")
            }
        }
    }
}

struct ProgressButton: View {
    let title: LocalizedStringKey
    let isWorking: Bool
    let action: () -> Void

    init(_ title: LocalizedStringKey, isWorking: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isWorking = isWorking
        self.action = action
    }

    var body: some View {
        if isWorking {
            ProgressView()
        } else {
            Button(title, action: action)
                .fontWeight(.semibold)
        }
    }
}
