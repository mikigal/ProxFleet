import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI
import UniformTypeIdentifiers

/// The node's certificates: the cluster CA, the default node certificate and a custom one, which can be
/// uploaded or removed.
struct NodeCertificatesView: View {
    let detail: NodeDetail
    @State private var uploads = false
    @State private var confirmsDelete = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var hasCustom: Bool { detail.certificates?.contains { $0.isCustom } ?? false }

    var body: some View {
        List {
            if let certificates = detail.certificates {
                Section {
                    ForEach(certificates) { certificate in
                        NavigationLink {
                            CertificateDetailView(certificate: certificate)
                        } label: {
                            CertificateRow(certificate: certificate, isServed: isServed(certificate))
                        }
                        .accessibilityIdentifier("certificate.\(certificate.fileName)")
                    }
                } footer: {
                    if detail.isBackupServer {
                        Text("The certificate the server's web interface and API use. A custom one replaces it; the app then trusts the new certificate.")
                    } else {
                        Text("The node serves the custom certificate when there is one, otherwise its default certificate, which the cluster's CA signed.")
                    }
                }
                Section {
                    Button {
                        uploads = true
                    } label: {
                        Label("Upload Custom Certificate", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("certificates.upload")
                    // A backup server makes a new self-signed certificate instead, which the app would have to trust
                    // anew; that is left to the web interface.
                    if hasCustom, !detail.isBackupServer {
                        Button(role: .destructive) {
                            confirmsDelete = true
                        } label: {
                            HStack {
                                Label("Delete Custom Certificate", systemImage: "trash")
                                Spacer()
                                if isDeleting { ProgressView() }
                            }
                        }
                        .accessibilityIdentifier("certificates.delete")
                    }
                } footer: {
                    Text("Ordering certificates with ACME (Let's Encrypt) is not available in the app yet.")
                }
                .disabled(!detail.can("Sys.Modify") || isDeleting)
            }
        }
        .overlay {
            if let errorMessage, detail.certificates == nil {
                ContentUnavailableView("Cannot Load the Certificates", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if detail.certificates == nil {
                ProgressView()
            }
        }
        .navigationTitle("Certificates")
        .refreshable { errorMessage = await detail.loadCertificates() }
        .task { errorMessage = await detail.loadCertificates() }
        .sheet(isPresented: $uploads) {
            NavigationStack {
                UploadCertificateView(detail: detail)
            }
        }
        .confirmationDialog("Delete the custom certificate?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The node goes back to its default certificate, signed by the cluster's own CA. Browsers then warn about it again.")
        }
        .alert("Certificate Error", isPresented: Binding(get: { errorMessage != nil && detail.certificates != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func isServed(_ certificate: NodeCertificate) -> Bool {
        certificate.isCustom || (certificate.fileName == "pve-ssl.pem" && !hasCustom) || certificate.fileName == "proxy.pem"
    }

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await detail.deleteCustomCertificate()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CertificateRow: View {
    let certificate: NodeCertificate
    let isServed: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: certificate.isAuthority ? "building.columns" : "checkmark.seal")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(certificate.commonName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if isServed {
                        Text("In Use")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: .capsule)
                            .foregroundStyle(.green)
                    }
                }
                Text(certificate.kindTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notAfter = certificate.notAfter {
                    Text(certificate.isExpired() ? "Expired \(notAfter.formatted(date: .abbreviated, time: .omitted))" : "Expires \(notAfter.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(certificate.isExpired() ? .red : certificate.expiresSoon() ? .orange : .secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension NodeCertificate {
    var kindTitle: String {
        switch fileName {
        case "pve-root-ca.pem": String(localized: "Cluster CA")
        case "pve-ssl.pem": String(localized: "Default node certificate")
        case "pveproxy-ssl.pem": String(localized: "Custom certificate")
        case "proxy.pem": String(localized: "Server certificate")
        default: fileName
        }
    }
}

private struct CertificateDetailView: View {
    let certificate: NodeCertificate

    var body: some View {
        List {
            Section {
                LabeledContent("Subject") { Text(certificate.subject).textSelection(.enabled) }
                LabeledContent("Issuer") { Text(certificate.issuer).textSelection(.enabled) }
                if let notBefore = certificate.notBefore {
                    LabeledContent("Valid From", value: notBefore.formatted(date: .abbreviated, time: .shortened))
                }
                if let notAfter = certificate.notAfter {
                    LabeledContent("Valid Until", value: notAfter.formatted(date: .abbreviated, time: .shortened))
                }
                if let type = certificate.keyType {
                    LabeledContent("Public Key", value: certificate.keyBits.map { "\(type), \($0) bits" } ?? type)
                }
                LabeledContent("File", value: certificate.fileName)
            }
            if !certificate.subjectAlternativeNames.isEmpty {
                Section("Alternative Names") {
                    ForEach(certificate.subjectAlternativeNames, id: \.self) { name in
                        Text(name).textSelection(.enabled)
                    }
                }
            }
            if let fingerprint = certificate.fingerprint {
                Section("SHA-256 Fingerprint") {
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            if let pem = certificate.pem {
                Section {
                    ShareLink(item: pem, preview: SharePreview(certificate.fileName)) {
                        Label("Share PEM", systemImage: "square.and.arrow.up")
                    }
                    Button("Copy PEM", systemImage: "doc.on.doc") { UIPasteboard.general.string = pem }
                }
            }
        }
        .navigationTitle(certificate.commonName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Paste or import a PEM certificate chain and key.
private struct UploadCertificateView: View {
    let detail: NodeDetail
    @State private var draft = CustomCertificateDraft()
    @State private var importing: ImportTarget?
    @State private var isUploading = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    private enum ImportTarget: Identifiable {
        case certificates, key
        var id: Self { self }
    }

    private var errors: [String: String] { showsProblems ? draft.problems.merging(fieldErrors) { _, server in server } : fieldErrors }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draft.certificates)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 160)
                    .accessibilityIdentifier("certificate.pem")
                Button("Import from Files", systemImage: "folder") { importing = .certificates }
                FieldError(message: errors["certificates"])
            } header: {
                Text("Certificate Chain")
            } footer: {
                Text("The certificate first, then any intermediate certificates.")
            }
            Section {
                TextEditor(text: $draft.key)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 120)
                    .accessibilityIdentifier("certificate.key")
                Button("Import from Files", systemImage: "folder") { importing = .key }
                FieldError(message: errors["key"])
            } header: {
                Text("Private Key")
            } footer: {
                Text("Leave empty to keep the key already on the node. The key is sent to the node only.")
            }
            Section {
            } footer: {
                Text("The node's web service restarts to use the new certificate. The app trusts the new certificate automatically.")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Custom Certificate")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isUploading)
        .disabled(isUploading)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Upload", isWorking: isUploading) { Task { await upload() } }
                    .accessibilityIdentifier("certificate.upload")
            }
        }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: [.x509Certificate, .text, .data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                errorMessage = String(localized: "The file is not a PEM text file.")
                return
            }
            switch importing {
            case .certificates: draft.certificates = text
            case .key: draft.key = text
            case nil: break
            }
            importing = nil
        }
    }

    private func upload() async {
        showsProblems = true
        fieldErrors = [:]
        guard draft.problems.isEmpty else { return }
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }
        do {
            try await detail.uploadCertificate(draft)
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
