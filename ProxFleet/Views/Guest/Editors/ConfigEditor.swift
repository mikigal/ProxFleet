import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Form scaffold shared by the configuration editors: Save button, saving state, validation and conflict errors.
///
/// `makeUpdate` returns nil while nothing changed, which disables Save.
struct ConfigEditor<Content: View>: View {
    let title: LocalizedStringKey
    let detail: GuestDetail
    let makeUpdate: () -> GuestConfigUpdate?
    var footer: LocalizedStringKey?
    @ViewBuilder let content: (_ fieldErrors: [String: String]) -> Content

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            content(fieldErrors)
            if detail.powerState == .running {
                Section {
                } footer: {
                    Text(footer ?? "Some changes apply only after the VM restarts. Those are shown as pending until then.")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Save", isWorking: isSaving) { Task { await save() } }
                    .disabled(makeUpdate() == nil)
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func save() async {
        guard let update = makeUpdate() else { return }
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { isSaving = false }
        do {
            try await detail.apply(update)
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Validation message under a field.
struct FieldError: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

/// Integer field with a stepper, for counts and sizes.
struct NumberField: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step = 1
    var unit: String?

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                TextField("", value: $value, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    .monospacedDigit()
                if let unit {
                    Text(unit).foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension GuestDetail {
    /// Loads a list for an editor, e.g. storages or bridges. Returns an empty list on failure.
    func load<Item: Decodable & Sendable>(_ request: APIRequest<[Item]>) async -> [Item] {
        (try? await connection.send(request)) ?? []
    }
}
