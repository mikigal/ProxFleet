import FleetCore
import SwiftUI

/// Shows whatever a server needs right now: a sign-in step, an error, or its overview.
struct ServerDetailView: View {
    let connection: ServerConnection

    var body: some View {
        content
            .navigationTitle(connection.profile.name)
            .task { await connection.connect() }
    }

    @ViewBuilder
    private var content: some View {
        switch connection.state {
        case .disconnected, .connecting:
            ProgressView("Connecting to \(connection.profile.addressSummary)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsPassword(let message):
            PasswordPrompt(userID: connection.profile.userID, message: message) { password, remember in
                Task { await connection.signIn(password: password, remember: remember) }
            }
        case .needsSecondFactor(let challenge):
            SecondFactorForm(challenge: challenge, isWorking: false, errorMessage: connection.signInError) { method, code in
                Task { await connection.submitSecondFactor(challenge, method: method, code: code) }
            }
        case .untrustedCertificate(let certificate, let previouslyTrusted):
            CertificateTrustView(certificate: certificate, host: connection.currentAddress.host, previouslyTrusted: previouslyTrusted, isWorking: false) {
                Task { await connection.trust(certificate) }
            }
        case .connected:
            ServerOverviewView(connection: connection)
        case .failed(let message):
            ContentUnavailableView {
                Label("Cannot Connect", systemImage: "network.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await connection.connect() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
