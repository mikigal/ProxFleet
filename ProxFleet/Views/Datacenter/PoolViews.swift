import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The datacenter's resource pools: groups of guests and storages that share permissions.
struct PoolsView: View {
    @State private var list: PoolList
    @State private var creating = false
    @State private var deleting: ResourcePool?
    @State private var errorMessage: String?

    init(connection: ServerConnection) {
        _list = State(initialValue: PoolList(connection: connection))
    }

    var body: some View {
        List {
            if let pools = list.pools, !pools.isEmpty {
                Section {
                    ForEach(pools) { pool in
                        NavigationLink {
                            PoolDetailView(list: list, poolID: pool.id)
                        } label: {
                            PoolRow(pool: pool, guestCount: guestCount(pool.id))
                        }
                        .accessibilityIdentifier("pool.\(pool.id)")
                        .swipeActions {
                            if list.canModify {
                                Button("Delete", systemImage: "trash") { deleting = pool }
                                    .tint(.red)
                            }
                        }
                    }
                } footer: {
                    Text("Permissions given on a pool apply to its guests and storages. Pools can be nested as parent/child.")
                }
            }
        }
        .overlay {
            if let error = list.loadError, list.pools == nil {
                ContentUnavailableView("Cannot Load Pools", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if list.pools == nil {
                ProgressView()
            } else if list.pools?.isEmpty == true {
                ContentUnavailableView("No Pools", systemImage: "square.stack.3d.down.right",
                                       description: Text("Pools group guests and storages, so permissions can be given for all of them at once."))
            }
        }
        .navigationTitle("Pools")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .disabled(!list.canModify)
                    .accessibilityIdentifier("pool.add")
            }
        }
        .refreshable { await list.load() }
        .task { await list.load() }
        .sheet(isPresented: $creating) {
            NavigationStack { NewPoolView(list: list) }
        }
        .confirmationDialog("Delete the pool \(deleting?.id ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { pool in
            Button("Delete", role: .destructive) { Task { await delete(pool) } }
        } message: { _ in
            Text("Only empty pools can be deleted: remove its guests, storages and nested pools first.")
        }
        .accessError($errorMessage)
    }

    /// Guests per pool come with the cluster's resources, so the list does not load every pool.
    private func guestCount(_ id: String) -> Int {
        list.connection.snapshot?.guests.filter { $0.pool == id }.count ?? 0
    }

    private func delete(_ pool: ResourcePool) async {
        do {
            try await list.delete(pool.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PoolRow: View {
    let pool: ResourcePool
    let guestCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(pool.id)
                    .font(.body.weight(.medium))
                Text([pool.comment, String(AttributedString(localized: "^[\(guestCount) guest](inflect: true)").characters)]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct NewPoolView: View {
    let list: PoolList
    @State private var name = ""
    @State private var comment = ""
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section {
                LabeledTextField(title: "Name", prompt: "production", text: $name, identifier: "pool.name")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if showsProblems { FieldError(message: ResourcePool.problem(forName: trimmedName)) }
                LabeledTextField(title: "Comment", prompt: "None", text: $comment, identifier: "pool.comment")
            } footer: {
                if let parents = list.pools?.map(\.id), !parents.isEmpty {
                    Text("To nest a pool, put its parent first: \(parents[0])/name.")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("New Pool")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Add", isWorking: isSaving) { Task { await save() } }
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func save() async {
        showsProblems = true
        guard ResourcePool.problem(forName: trimmedName) == nil else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await list.create(trimmedName, comment: comment)
            dismiss()
        } catch .invalid(let message, let fields) {
            errorMessage = fields["poolid"] ?? message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Pool

struct PoolDetailView: View {
    let list: PoolList
    let poolID: String
    @State private var access: AccessControl
    @State private var comment = ""
    @State private var adding: AddMembersView.Kind?
    @State private var addsPermission = false
    @State private var removing: PoolDetail.Member?
    @State private var errorMessage: String?

    init(list: PoolList, poolID: String) {
        self.list = list
        self.poolID = poolID
        _access = State(initialValue: AccessControl(connection: list.connection))
    }

    private var detail: PoolDetail? { list.details[poolID] }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Comment", text: $comment, prompt: Text("None"))
                        .accessibilityIdentifier("pool.detail.comment")
                    if comment != (detail?.comment ?? "") {
                        Button("Save") { Task { await saveComment() } }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("pool.detail.saveComment")
                    }
                }
            } header: {
                Text("Comment")
            }
            .disabled(!list.canModify)
            Section {
                if let detail, detail.guests.isEmpty {
                    Text("No guests").foregroundStyle(.secondary)
                }
                ForEach(detail?.guests ?? []) { member in
                    memberRow(member)
                }
                Button("Add Guests", systemImage: "plus") { adding = .guests }
                    .disabled(!list.canModify)
                    .accessibilityIdentifier("pool.addGuests")
            } header: {
                Text("Guests")
            }
            Section {
                if let detail, detail.storages.isEmpty {
                    Text("No storage").foregroundStyle(.secondary)
                }
                ForEach(detail?.storages ?? [], id: \.self) { storage in
                    Label(storage, systemImage: "externaldrive")
                        .accessibilityIdentifier("pool.member.storage.\(storage)")
                        .swipeActions {
                            if list.canModify {
                                Button("Remove", systemImage: "minus.circle") {
                                    Task { await remove(guests: [], storages: [storage]) }
                                }
                                .tint(.red)
                            }
                        }
                }
                Button("Add Storage", systemImage: "plus") { adding = .storages }
                    .disabled(!list.canModify)
                    .accessibilityIdentifier("pool.addStorage")
            } header: {
                Text("Storage")
            } footer: {
                Text("Removing a member only takes it out of the pool; the guest or storage itself stays.")
            }
            PermissionList(access: access, entries: (access.acl ?? []).filter { $0.path == "/pool/\(poolID)" }, adding: $addsPermission,
                           footer: "Users, groups and tokens with a role on this pool. Pool.Audit lets users see it in the web interface.", showsPath: false)
        }
        .navigationTitle(poolID)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if detail == nil { ProgressView() }
        }
        .refreshable { await reload() }
        .task {
            await reload()
            comment = detail?.comment ?? ""
        }
        .sheet(item: $adding) { kind in
            NavigationStack { AddMembersView(list: list, poolID: poolID, kind: kind) }
        }
        .sheet(isPresented: $addsPermission) {
            NavigationStack {
                PermissionEditor(access: access, entry: ACLEntry(path: "/pool/\(poolID)", subject: .user, subjectID: "", role: ""))
            }
        }
        .accessError($errorMessage)
    }

    private func memberRow(_ member: PoolDetail.Member) -> some View {
        HStack(spacing: 12) {
            Image(systemName: member.kind == .lxc ? "shippingbox" : "desktopcomputer")
                .foregroundStyle(member.status == "running" ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name ?? member.id)
                    .font(.body.weight(.medium))
                Text([member.vmid.map(String.init), member.node, member.isTemplate ? String(localized: "Template") : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pool.member.\(member.vmid ?? 0)")
        .swipeActions {
            if list.canModify, let vmid = member.vmid {
                Button("Remove", systemImage: "minus.circle") {
                    Task { await remove(guests: [vmid], storages: []) }
                }
                .tint(.red)
            }
        }
    }

    private func reload() async {
        async let detail: Void = list.loadDetail(poolID)
        async let permissions: Void = access.load()
        _ = await (detail, permissions)
    }

    private func saveComment() async {
        do {
            try await list.updateComment(poolID, comment: comment)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(guests: [Int], storages: [String]) async {
        do {
            try await list.removeMembers(from: poolID, guests: guests, storages: storages)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Picks guests or storages to add to a pool. Guests already in another pool are moved, as in the web interface.
struct AddMembersView: View {
    enum Kind: String, Identifiable {
        case guests, storages

        var id: String { rawValue }
    }

    let list: PoolList
    let poolID: String
    let kind: Kind
    @State private var guests: Set<Int> = []
    @State private var storages: Set<String> = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var detail: PoolDetail? { list.details[poolID] }

    private var candidateGuests: [GuestSummary] {
        (list.connection.snapshot?.guests ?? []).filter { $0.pool != poolID }.sorted { $0.vmid < $1.vmid }
    }

    private var candidateStorages: [String] {
        let current = Set(detail?.storages ?? [])
        return Array(Set((list.connection.snapshot?.storages ?? []).map(\.name))).filter { !current.contains($0) }.sorted()
    }

    var body: some View {
        Form {
            switch kind {
            case .guests:
                Section {
                    if candidateGuests.isEmpty {
                        Text("Every guest is in this pool already.").foregroundStyle(.secondary)
                    }
                    ForEach(candidateGuests) { guest in
                        Toggle(isOn: Binding(get: { guests.contains(guest.vmid) }, set: { on in
                            if on { guests.insert(guest.vmid) } else { guests.remove(guest.vmid) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(String(guest.vmid)) · \(guest.name)")
                                if let pool = guest.pool {
                                    Text("In pool \(pool)")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .accessibilityIdentifier("pool.candidate.\(guest.vmid)")
                    }
                } footer: {
                    Text("Guests that are in another pool already are taken out of it first.")
                }
            case .storages:
                Section {
                    if candidateStorages.isEmpty {
                        Text("Every storage is in this pool already.").foregroundStyle(.secondary)
                    }
                    ForEach(candidateStorages, id: \.self) { storage in
                        Toggle(storage, isOn: Binding(get: { storages.contains(storage) }, set: { on in
                            if on { storages.insert(storage) } else { storages.remove(storage) }
                        }))
                        .accessibilityIdentifier("pool.candidate.\(storage)")
                    }
                } footer: {
                    Text("A storage can be in several pools.")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(kind == .guests ? "Add Guests" : "Add Storage")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Add", isWorking: isSaving) { Task { await save() } }
                    .disabled(guests.isEmpty && storages.isEmpty)
                    .accessibilityIdentifier("save")
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await list.addMembers(to: poolID, guests: Array(guests), storages: Array(storages))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
