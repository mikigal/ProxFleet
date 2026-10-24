import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// External metric servers the nodes send their statistics to: Graphite, InfluxDB and OpenTelemetry.
struct MetricServersView: View {
    @State private var settings: MetricServerSettings
    @State private var creating: MetricServerType?
    @State private var deleting: MetricServer?
    @State private var errorMessage: String?

    init(connection: ServerConnection) {
        _settings = State(initialValue: MetricServerSettings(connection: connection))
    }

    var body: some View {
        List {
            if let servers = settings.servers {
                Section {
                    if servers.isEmpty {
                        Text("No metric servers").foregroundStyle(.secondary)
                    }
                    ForEach(servers) { server in
                        NavigationLink {
                            MetricServerEditorLoader(settings: settings, server: server)
                        } label: {
                            row(server)
                        }
                        .accessibilityIdentifier("metric.\(server.id)")
                        .swipeActions {
                            if settings.canModify {
                                Button("Delete", systemImage: "trash") { deleting = server }
                                    .tint(.red)
                            }
                        }
                    }
                } footer: {
                    Text("Every node sends the statistics of itself, its guests and storage to these servers.")
                }
            }
        }
        .overlay {
            if let error = settings.loadError, settings.servers == nil {
                ContentUnavailableView("Cannot Load the Metric Servers", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if settings.servers == nil {
                ProgressView()
            }
        }
        .navigationTitle("Metric Servers")
        .refreshable { await settings.load() }
        .task { await settings.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    ForEach(MetricServerType.allCases.filter { $0 != .opentelemetry || settings.connection.supports(.metricServerOpenTelemetry) }) { type in
                        Button(type.title) { creating = type }
                            .accessibilityIdentifier("metric.add.\(type.rawValue)")
                    }
                }
                .disabled(!settings.canModify)
                .accessibilityIdentifier("metric.add")
            }
        }
        .sheet(item: $creating) { type in
            NavigationStack { MetricServerEditor(settings: settings, draft: MetricServerDraft(type: type), isNew: true) }
        }
        .confirmationDialog("Delete \(deleting?.id ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { server in
            Button("Delete", role: .destructive) {
                Task {
                    do { try await settings.delete(server.id) } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { _ in
            Text("The nodes stop sending statistics to it.")
        }
        .alert("Metric Server Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ server: MetricServer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.title3)
                .foregroundStyle(server.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.id).font(.body.weight(.medium))
                    if !server.isEnabled { AccessBadge(text: "Disabled") }
                }
                Text([MetricServerType(rawValue: server.type)?.title ?? server.type, "\(server.server):\(server.port)"].joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Loads all settings of a server, which the list leaves out, then shows the editor.
private struct MetricServerEditorLoader: View {
    let settings: MetricServerSettings
    let server: MetricServer
    @State private var draft: MetricServerDraft?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let draft {
                MetricServerEditor(settings: settings, draft: draft, isNew: false)
            } else if let errorMessage {
                ContentUnavailableView("Cannot Load the Server", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(server.id)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                var full = try await settings.server(server.id)
                full.id = server.id
                if let draft = MetricServerDraft(full) {
                    self.draft = draft
                } else {
                    errorMessage = String(localized: "The app does not know metric servers of the type \(full.type).")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct MetricServerEditor: View {
    let settings: MetricServerSettings
    let isNew: Bool
    let original: MetricServerDraft
    @State private var draft: MetricServerDraft
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(settings: MetricServerSettings, draft: MetricServerDraft, isNew: Bool) {
        self.settings = settings
        self.isNew = isNew
        original = draft
        _draft = State(initialValue: draft)
    }

    private var errors: [String: String] {
        (showsProblems ? draft.problems(isNew: isNew) : [:]).merging(fieldErrors) { _, server in server }
    }

    var body: some View {
        Form {
            if !settings.canModify {
                Section {
                    Label("Read only. Changing metric servers needs the Sys.Modify privilege on /.", systemImage: "lock.fill")
                        .font(.subheadline)
                }
            }
            Group {
                Section {
                    if isNew {
                        LabeledTextField(title: "Name", prompt: "influx", text: $draft.id, identifier: "metric.id")
                        FieldError(message: errors["id"])
                    }
                    LabeledTextField(title: "Server", prompt: "metrics.example.com", text: $draft.server, keyboard: .URL, identifier: "metric.server")
                    FieldError(message: errors["server"])
                    LabeledTextField(title: "Port", prompt: LocalizedStringKey(draft.type.defaultPort), text: $draft.port, keyboard: .numberPad, identifier: "metric.port")
                    FieldError(message: errors["port"])
                    Toggle("Enabled", isOn: $draft.isEnabled)
                        .accessibilityIdentifier("metric.enabled")
                } footer: {
                    if draft.type == .opentelemetry || draft.usesHTTP || draft.graphiteProtocol == "tcp", draft.isEnabled {
                        Text("Proxmox checks that the server answers before it saves.")
                    }
                }
                switch draft.type {
                case .graphite: graphiteSections
                case .influxdb: influxSections
                case .opentelemetry: openTelemetrySections
                }
            }
            .disabled(!settings.canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? "New \(draft.type.title) Server" : draft.id)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if settings.canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!isNew && draft.changes(from: original).isEmpty)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    @ViewBuilder
    private var graphiteSections: some View {
        Section {
            LabeledTextField(title: "Path", prompt: "proxmox", text: $draft.path, identifier: "metric.path")
            Picker("Protocol", selection: $draft.graphiteProtocol) {
                Text(verbatim: "UDP").tag("")
                Text(verbatim: "TCP").tag("tcp")
            }
            if draft.graphiteProtocol == "tcp" {
                LabeledTextField(title: "TCP Timeout", prompt: "1", text: $draft.timeout, keyboard: .numberPad)
                FieldError(message: errors["timeout"])
            } else {
                LabeledTextField(title: "MTU", prompt: "1500", text: $draft.mtu, keyboard: .numberPad)
                FieldError(message: errors["mtu"])
            }
        } footer: {
            Text("Metrics are named below the path, such as proxmox.nodes.pve1.cpu.")
        }
    }

    @ViewBuilder
    private var influxSections: some View {
        Section {
            Picker("Protocol", selection: $draft.influxProtocol) {
                Text(verbatim: "UDP").tag("")
                Text(verbatim: "HTTP").tag("http")
                Text(verbatim: "HTTPS").tag("https")
            }
            .accessibilityIdentifier("metric.protocol")
            if !draft.usesHTTP {
                LabeledTextField(title: "MTU", prompt: "1500", text: $draft.mtu, keyboard: .numberPad)
                FieldError(message: errors["mtu"])
            }
        } footer: {
            Text(draft.usesHTTP ? "InfluxDB 2 and later take metrics over HTTP(S) with an organization, a bucket and a token." : "UDP needs the UDP listener of InfluxDB 1, usually on port 8089.")
        }
        if draft.usesHTTP {
            Section {
                LabeledTextField(title: "Organization", prompt: "proxmox", text: $draft.organization, identifier: "metric.organization")
                LabeledTextField(title: "Bucket", prompt: "proxmox", text: $draft.bucket, identifier: "metric.bucket")
                LabeledContent("Token") {
                    SecureField("Token", text: $draft.token, prompt: Text(isNew ? "None" : "Unchanged"))
                        .multilineTextAlignment(.trailing)
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("metric.token")
                }
            } header: {
                Text("InfluxDB")
            } footer: {
                Text("With the InfluxDB 1.8 compatibility API, use user:password as the token.")
            }
            Section {
                LabeledTextField(title: "API Path Prefix", prompt: "None", text: $draft.apiPathPrefix)
                LabeledTextField(title: "Timeout (s)", prompt: "1", text: $draft.timeout, keyboard: .numberPad)
                FieldError(message: errors["timeout"])
                LabeledTextField(title: "Batch Size (bytes)", prompt: "25000000", text: $draft.maxBodySize, keyboard: .numberPad)
                FieldError(message: errors["max-body-size"])
                if draft.influxProtocol == "https" {
                    Toggle("Verify Certificate", isOn: $draft.verifiesCertificate)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("The path prefix goes between the address and /api/v2, for InfluxDB behind a reverse proxy.")
            }
        }
    }

    @ViewBuilder
    private var openTelemetrySections: some View {
        Section {
            Picker("Protocol", selection: $draft.otelProtocol) {
                Text(verbatim: "HTTP").tag("http")
                Text(verbatim: "HTTPS").tag("https")
            }
            .accessibilityIdentifier("metric.otelprotocol")
            LabeledTextField(title: "Path", prompt: "/v1/metrics", text: $draft.otelPath, identifier: "metric.otelpath")
            LabeledTextField(title: "Timeout (s)", prompt: "5", text: $draft.otelTimeout, keyboard: .numberPad)
            FieldError(message: errors["otel-timeout"])
            if draft.otelProtocol == "https" {
                Toggle("Verify Certificate", isOn: $draft.otelVerifiesSSL)
            }
        } header: {
            Text("OTLP over HTTP")
        }
        Section {
            LabeledTextField(title: "Max Body Size (bytes)", prompt: "10000000", text: $draft.otelMaxBodySize, keyboard: .numberPad)
            FieldError(message: errors["otel-max-body-size"])
            Picker("Compression", selection: $draft.otelCompression) {
                Text("Default (Gzip)").tag("")
                Text("None").tag("none")
                Text(verbatim: "Gzip").tag("gzip")
            }
            jsonField("HTTP Headers", text: $draft.otelHeaders, prompt: #"{"Authorization": "Bearer …"}"#, error: errors["otel-headers"])
            jsonField("Resource Attributes", text: $draft.otelResourceAttributes, prompt: #"{"environment": "production"}"#, error: errors["otel-resource-attributes"])
        } header: {
            Text("Advanced")
        } footer: {
            Text("Headers and resource attributes are JSON objects. Headers are sent with every request, for example for authentication.")
        }
    }

    @ViewBuilder
    private func jsonField(_ title: LocalizedStringKey, text: Binding<String>, prompt: String, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextField(title, text: text, prompt: Text(verbatim: prompt), axis: .vertical)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2...6)
        }
        FieldError(message: error)
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
                try await settings.create(draft)
            } else {
                try await settings.update(draft, draft.changes(from: original))
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
