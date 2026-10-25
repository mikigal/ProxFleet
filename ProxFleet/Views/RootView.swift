import FleetCore
import SwiftUI

struct RootView: View {
    @Environment(Fleet.self) private var fleet
    @State private var selection: UUID?
    @State private var compactColumn: NavigationSplitViewColumn
    @State private var columnVisibility: NavigationSplitViewVisibility

    init(initialSelection: UUID?) {
        _selection = State(initialValue: initialSelection)
        _compactColumn = State(initialValue: initialSelection == nil ? .sidebar : .detail)
        _columnVisibility = State(initialValue: initialSelection == nil ? .all : .detailOnly)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            ServerListView(selection: $selection)
        } detail: {
            if let selection, let connection = fleet.connection(for: selection) {
                NavigationStack {
                    ServerDetailView(connection: connection)
                }
                .id(selection)
            } else {
                ContentUnavailableView("No Server Selected", systemImage: "server.rack", description: Text("Choose a server from the list."))
            }
        }
        // On iPhone the split view collapses into one stack, which pushed screens take their environment from.
        .environment(\.openServer, OpenServerAction { selection = $0 })
        .onChange(of: selection) {
            // On iPad the server list gets out of the way once a server is open; the toolbar button brings it back.
            withAnimation {
                columnVisibility = selection == nil ? .all : .detailOnly
            }
        }
        .onChange(of: fleet.profiles) {
            if let selection, fleet.profile(id: selection) == nil {
                self.selection = nil
            }
        }
    }
}

#Preview {
    let fleet = Fleet(environment: .inMemory())
    let demo = fleet.addDemoServer()
    return RootView(initialSelection: demo.id)
        .environment(fleet)
        .environment(AppLock(store: InMemoryAppLockStore()))
}
