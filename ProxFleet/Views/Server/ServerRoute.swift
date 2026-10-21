import FleetCore
import PVEKit
import SwiftUI

/// Screens that can be pushed inside a server's navigation stack.
enum ServerRoute: Hashable {
    case guest(GuestReference)
    case node(String)
    case tasks
    case task(node: String, upid: String)
}

extension View {
    func serverDestinations(_ connection: ServerConnection) -> some View {
        navigationDestination(for: ServerRoute.self) { route in
            switch route {
            case .guest(let reference):
                GuestDetailView(reference: reference, connection: connection)
            case .node(let name):
                NodeDetailView(node: name, connection: connection)
            case .tasks:
                TasksView(connection: connection)
            case .task(let node, let upid):
                TaskLogView(connection: connection, node: node, upid: upid)
            }
        }
    }
}
