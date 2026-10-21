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
    /// When set and the user lacks it, the form is shown read-only with an explanation.
    var privilege: String?
    /// Called after a successful save instead of closing the editor, e.g. to close a parent screen as well.
    var onSaved: (() -> Void)?
    @ViewBuilder let content: (_ fieldErrors: [String: String]) -> Content

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    /// Digest of the configuration the form was filled from, so changes made elsewhere meanwhile are detected.
    @State private var digest: String?
    @Environment(\.dismiss) private var dismiss

    private var isReadOnly: Bool {
        privilege.map { !detail.can($0) } ?? false
    }

    var body: some View {
        Form {
            if isReadOnly, let privilege {
                Section {
                    Label {
                        Text("Read only. Changing this needs the \(privilege) privilege on /vms/\(String(detail.reference.vmid)).")
                    } icon: {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            Group {
                content(fieldErrors)
            }
            .disabled(isReadOnly)
            if detail.powerState == .running, !isReadOnly {
                Section {
                } footer: {
                    Text(footer ?? "Some changes apply only after the guest restarts. Those are shown as pending until then.")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            if !isReadOnly {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton("Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(makeUpdate() == nil)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    private func save() async {
        guard var update = makeUpdate() else { return }
        if update.digest == nil { update.digest = digest }
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { isSaving = false }
        do {
            try await detail.apply(update)
            if let onSaved { onSaved() } else { dismiss() }
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch .conflict {
            // Saving again overwrites the other change, as in the web interface.
            digest = detail.config?.digest
            errorMessage = ConfigUpdateError.conflict.localizedDescription
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

extension ServerConnection {
    /// Loads a list for a form, e.g. storages or bridges. Returns an empty list on failure.
    func load<Item: Decodable & Sendable>(_ request: APIRequest<[Item]>) async -> [Item] {
        (try? await send(request)) ?? []
    }

    /// Volumes with a content type (`iso`, `vztmpl`…) on every storage of a node, sorted by file name.
    func volumes(node: String, content: String) async -> [StorageVolume] {
        var volumes: [StorageVolume] = []
        for storage in await load(PVE.storages(node: node, content: content)) {
            volumes += await load(PVE.storageContent(node: node, storage: storage.storage, content: content))
        }
        return volumes.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }
}

extension GuestDetail {
    /// Loads a list for an editor, e.g. storages or bridges. Returns an empty list on failure.
    func load<Item: Decodable & Sendable>(_ request: APIRequest<[Item]>) async -> [Item] {
        await connection.load(request)
    }
}

/// Tags as removable chips plus a field to add new ones.
struct TagsEditor: View {
    @Binding var tags: [String]
    @State private var newTag = ""
    @State private var invalid = false

    var body: some View {
        if !tags.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Button {
                        tags.removeAll { $0 == tag }
                    } label: {
                        HStack(spacing: 4) {
                            Text(tag)
                            Image(systemName: "xmark.circle.fill").font(.caption)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove tag \(tag)")
                }
            }
            .padding(.vertical, 4)
        }
        HStack {
            TextField("Add Tag", text: $newTag)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(add)
                .accessibilityIdentifier("tags.new")
            Button("Add", action: add)
                .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if invalid {
            FieldError(message: String(localized: "Use lowercase letters, digits, and _ - + . only."))
        }
    }

    private func add() {
        guard let tag = TagRules.normalize(newTag) else {
            invalid = !newTag.isEmpty
            return
        }
        invalid = false
        if !tags.contains(tag) { tags.append(tag) }
        newTag = ""
    }
}

/// Lays out views in rows, wrapping to the next row when full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Explains why a value cannot be changed when its row is tapped.
struct LockedRowModifier: ViewModifier {
    let message: LocalizedStringKey
    @State private var showsMessage = false

    func body(content: Content) -> some View {
        Button {
            showsMessage = true
        } label: {
            HStack {
                content
                Image(systemName: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .alert("Cannot Be Changed", isPresented: $showsMessage) {
            Button("OK") {}
        } message: {
            Text(message)
        }
    }
}

extension View {
    func locked(_ message: LocalizedStringKey) -> some View {
        modifier(LockedRowModifier(message: message))
    }
}
