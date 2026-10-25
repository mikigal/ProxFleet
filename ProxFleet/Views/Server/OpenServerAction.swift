import SwiftUI

/// Switches the app to another saved server, e.g. from a Proxmox VE storage to the backup server behind it.
struct OpenServerAction {
    let open: (UUID) -> Void

    func callAsFunction(_ id: UUID) { open(id) }
}

extension EnvironmentValues {
    /// Set by the root view; nil in previews and wherever no server list exists.
    @Entry var openServer: OpenServerAction?
}
