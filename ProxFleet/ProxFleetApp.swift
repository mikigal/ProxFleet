import FleetCore
import SwiftUI
import UIKit

@main
struct ProxFleetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var fleet: Fleet
    @State private var appLock: AppLock
    @Environment(\.scenePhase) private var scenePhase
    private let initialSelection: UUID?

    init() {
        let launch = LaunchOptions(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        let fleet = Fleet(environment: launch.environment)
        _fleet = State(initialValue: fleet)
        _appLock = State(initialValue: AppLock(store: launch.inMemory ? InMemoryAppLockStore() : KeychainAppLockStore()))
        initialSelection = launch.apply(to: fleet)
        fleet.connectAll()
    }

    var body: some Scene {
        WindowGroup {
            RootView(initialSelection: initialSelection)
                .reviewPrompt()
                .appLockCover()
                .environment(fleet)
                .environment(appLock)
        }
        .onChange(of: scenePhase) { old, new in
            if new == .background {
                appLock.didEnterBackground()
            } else if old == .background {
                appLock.willEnterForeground()
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.allowed
    }
}

/// Which way screens may turn. iPhone screens are made for portrait; the full-screen console allows landscape too.
@MainActor
enum OrientationLock {
    static var allowsLandscape = false {
        didSet {
            guard allowsLandscape != oldValue else { return }
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                // Every presented controller asks again, as the full-screen console is one of them.
                var controller = scene.keyWindow?.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
                if !allowsLandscape {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
                } else if UIDevice.current.orientation.isLandscape {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
                }
            }
        }
    }

    static var allowed: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad || allowsLandscape ? .all : .portrait
    }
}
