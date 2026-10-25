import FleetCore
import PBSKit
import SwiftUI

/// Form scaffold for backup server settings: Save button, saving state, field errors and conflicts.
///
/// `makeUpdate` returns nil while nothing changed, which disables Save.
struct BackupServerSettingsForm<Content: View>: View {
    let title: LocalizedStringKey
    /// When set, the form is read-only and says why.
    var lockMessage: String?
    let makeUpdate: () -> BackupServerConfigUpdate?
    let save: (BackupServerConfigUpdate) async throws(ConfigUpdateError) -> Void
    @ViewBuilder let content: (_ fieldErrors: [String: String]) -> Content

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let lockMessage {
                Section {
                    Label {
                        Text(lockMessage)
                    } icon: {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            Group {
                content(fieldErrors)
            }
            .disabled(lockMessage != nil)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            if lockMessage == nil {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton("Save", isWorking: isSaving) { Task { await submit() } }
                        .disabled(makeUpdate() == nil)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    private func submit() async {
        guard let update = makeUpdate() else { return }
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { isSaving = false }
        do {
            try await save(update)
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A calendar event (schedule) with the web interface's examples to pick from.
struct CalendarEventField: View {
    let title: LocalizedStringKey
    @Binding var schedule: String
    var prompt: LocalizedStringKey = "None"
    let identifier: String
    var error: String?

    /// The examples of the web interface's schedule field.
    static let examples: [(schedule: String, title: LocalizedStringKey)] = [
        ("*:0/30", "Every 30 minutes"), ("hourly", "Every hour"), ("0/2:00", "Every two hours"),
        ("2,22:30", "Every day 02:30 and 22:30"), ("21:00", "Every day 21:00"), ("daily", "Every day 00:00"),
        ("mon..fri 00:00", "Monday to Friday 00:00"), ("mon..fri *:00", "Monday to Friday, hourly"),
        ("sat 18:15", "Every Saturday 18:15"), ("monthly", "Every first day of the month 00:00"),
        ("sat *-1..7 02:00", "Every first Saturday of the month 02:00"), ("yearly", "First day of the year 00:00"),
    ]

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $schedule, prompt: Text(prompt))
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(identifier)
                Menu {
                    ForEach(Self.examples, id: \.schedule) { example in
                        Button {
                            schedule = example.schedule
                        } label: {
                            Text(example.title)
                            Text(verbatim: example.schedule)
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("Schedule Examples")
                .accessibilityIdentifier(identifier + ".examples")
            }
        }
        FieldError(message: error)
    }
}

/// The `keep-*` rules: how many snapshots of each period to keep.
struct KeepRulesFields: View {
    @Binding var retention: RetentionPolicy
    var errors: [String: String] = [:]

    var body: some View {
        field("Keep Last", \.last, key: "keep-last")
        field("Keep Hourly", \.hourly, key: "keep-hourly")
        field("Keep Daily", \.daily, key: "keep-daily")
        field("Keep Weekly", \.weekly, key: "keep-weekly")
        field("Keep Monthly", \.monthly, key: "keep-monthly")
        field("Keep Yearly", \.yearly, key: "keep-yearly")
    }

    @ViewBuilder
    private func field(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<RetentionPolicy, Int?>, key: String) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { retention[keyPath: keyPath] }, set: { retention[keyPath: keyPath] = $0.flatMap { $0 > 0 ? $0 : nil } }),
                      format: .number, prompt: Text("All"))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("retention.\(key)")
        }
        FieldError(message: errors[key])
    }
}

/// A privilege the user lacks, said the way the server's permission errors say it.
func missingPrivilegeMessage(_ privilege: String, on path: String) -> String {
    String(localized: "Read only. Changing this needs the \(privilege) privilege on \(path).")
}
