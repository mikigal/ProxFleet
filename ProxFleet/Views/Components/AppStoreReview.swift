import FleetCore
import StoreKit
import SwiftUI

enum AppStore {
    static let appID = "6825985713"
    /// Opens the App Store with the review form of the app.
    static let writeReviewURL = URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")!
}

extension View {
    /// Asks for an App Store rating when `ReviewPrompt` finds a good moment.
    func reviewPrompt() -> some View {
        modifier(ReviewPromptModifier())
    }
}

private struct ReviewPromptModifier: ViewModifier {
    @Environment(Fleet.self) private var fleet
    @Environment(AppLock.self) private var appLock
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content
            .task(id: fleet.reviewPrompt.isDue) {
                guard fleet.reviewPrompt.isDue else { return }
                // Lets the outcome of the task show first.
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                // Not over the lock screen, in the background or over the full-screen console.
                guard scenePhase == .active, !appLock.isLocked, !OrientationLock.allowsLandscape else {
                    fleet.reviewPrompt.postpone()
                    return
                }
                requestReview()
                fleet.reviewPrompt.didRequest()
            }
    }
}
