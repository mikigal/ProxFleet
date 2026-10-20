import FleetCore
import SwiftUI

@main
struct ProxFleetApp: App {
    @State private var fleet: Fleet
    private let initialSelection: UUID?

    init() {
        let launch = LaunchOptions(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        let fleet = Fleet(environment: launch.inMemory ? .inMemory() : .live())
        _fleet = State(initialValue: fleet)
        initialSelection = launch.apply(to: fleet)
    }

    var body: some Scene {
        WindowGroup {
            RootView(initialSelection: initialSelection)
                .environment(fleet)
        }
    }
}
