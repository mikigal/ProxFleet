import FleetCore
import SwiftUI

struct RootView: View {
    @Environment(Fleet.self) private var fleet
    @State private var selection: UUID?
    @State private var compactColumn: NavigationSplitViewColumn

    init(initialSelection: UUID?) {
        _selection = State(initialValue: initialSelection)
        _compactColumn = State(initialValue: initialSelection == nil ? .sidebar : .detail)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
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
