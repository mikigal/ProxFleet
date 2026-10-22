import FleetCore
import SwiftUI
import UIKit

extension View {
    /// Covers the window with the lock screen while the app is locked, and hides its contents in the app switcher.
    func appLockCover() -> some View {
        modifier(AppLockCover())
    }
}

private struct AppLockCover: ViewModifier {
    @Environment(AppLock.self) private var appLock
    @Environment(Fleet.self) private var fleet
    @Environment(\.scenePhase) private var scenePhase
    @State private var scene: UIWindowScene?
    @State private var window = LockWindow()

    func body(content: Content) -> some View {
        content
            .overlay {
                // Hides the contents until the lock window is up, e.g. right after launch.
                if appLock.isLocked {
                    Color(.systemBackground).ignoresSafeArea()
                }
            }
            .background(WindowSceneReader(scene: $scene))
            .onChange(of: isCovered, initial: true) { update() }
            .onChange(of: scene) { update() }
    }

    /// Locked, or unlocked but not in front (the app switcher takes its snapshot then).
    private var isCovered: Bool {
        appLock.isEnabled && (appLock.isLocked || scenePhase != .active)
    }

    private func update() {
        if isCovered, let scene {
            window.show(in: scene) {
                LockCoverView()
                    .environment(appLock)
                    .environment(fleet)
            }
        } else {
            window.hide(animated: scenePhase == .active)
        }
    }
}

/// A window above everything else in the scene, so sheets and the full-screen console are covered too.
@MainActor
private final class LockWindow {
    private var window: UIWindow?

    func show(in scene: UIWindowScene, @ViewBuilder content: () -> some View) {
        guard window?.windowScene !== scene else { return }
        // A keyboard left up in a sheet would stay above the cover.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .systemBackground
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
    }

    func hide(animated: Bool) {
        guard let window else { return }
        self.window = nil
        let previousKey = window.windowScene?.windows.first { $0 !== window && $0.windowLevel == .normal }
        guard animated else {
            window.isHidden = true
            previousKey?.makeKey()
            return
        }
        UIView.animate(withDuration: 0.25) {
            window.alpha = 0
        } completion: { _ in
            window.isHidden = true
            previousKey?.makeKey()
        }
    }
}

private struct WindowSceneReader: UIViewRepresentable {
    @Binding var scene: UIWindowScene?

    func makeUIView(context: Context) -> SceneView {
        let view = SceneView()
        view.onScene = { scene = $0 }
        return view
    }

    func updateUIView(_ uiView: SceneView, context: Context) {}

    final class SceneView: UIView {
        var onScene: ((UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            let scene = window?.windowScene
            DispatchQueue.main.async { self.onScene?(scene) }
        }
    }
}

private struct LockCoverView: View {
    @Environment(AppLock.self) private var appLock

    var body: some View {
        if appLock.isLocked {
            LockScreen()
        } else {
            AppMark()
        }
    }
}

private struct AppMark: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("ProxFleet")
                .font(.title2.weight(.semibold))
        }
    }
}

private struct LockScreen: View {
    @Environment(AppLock.self) private var appLock
    @Environment(Fleet.self) private var fleet
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var pin = ""
    @State private var failures = 0
    @State private var message: String?
    @State private var biometricsOffered: Int?
    @State private var confirmingReset = false

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(spacing: 48) {
                    header
                    entry
                }
            } else {
                VStack(spacing: 28) {
                    Spacer()
                    header
                    entry
                    Spacer()
                    forgotButton
                }
                .padding(.bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: offerBiometricsIfActive)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            offerBiometricsIfActive()
        }
        .onChange(of: appLock.lockGeneration) {
            pin = ""
            message = nil
            offerBiometricsIfActive()
        }
        .confirmationDialog("Reset ProxFleet?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Remove All Servers and Unlock", role: .destructive) {
                fleet.removeAllServers()
                appLock.disable()
            }
        } message: {
            Text("Without the PIN, the app can only be unlocked by removing every saved server, password and certificate approval from this device. Nothing changes on the servers.")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
            Text("Enter PIN")
                .font(.title3.weight(.semibold))
            status
                .font(.footnote)
                .multilineTextAlignment(.center)
                .frame(minHeight: 36, alignment: .top)
                .accessibilityIdentifier("lock.message")
            if verticalSizeClass == .compact {
                forgotButton
            }
        }
        .frame(maxWidth: 280)
    }

    @ViewBuilder
    private var status: some View {
        if let until = appLock.lockedOutUntil, until > .now {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, until.timeIntervalSince(context.date))
                Text("Too many wrong PINs. Try again in \(Duration.seconds(remaining.rounded(.up)).formatted(.time(pattern: .minuteSecond))).")
                    .foregroundStyle(.red)
            }
        } else if let message {
            Text(message)
                .foregroundStyle(.red)
        } else {
            Text(" ")
        }
    }

    private var entry: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            PINEntryView(
                pin: $pin,
                length: appLock.pinLength.rawValue,
                failures: failures,
                isDisabled: (appLock.lockedOutUntil ?? .distantPast) > context.date,
                biometrics: availableBiometrics.map { kind in (kind, startBiometrics) },
                onComplete: submit
            )
        }
    }

    private var forgotButton: some View {
        Button("Forgot PIN?") { confirmingReset = true }
            .font(.footnote)
            .accessibilityIdentifier("lock.forgot")
    }

    /// Face ID, unless it is off or the enrolled faces changed since it was turned on.
    private var availableBiometrics: Biometrics.Kind? {
        guard appLock.biometricsEnabled, enrollmentUnchanged else { return nil }
        return Biometrics.kind
    }

    private var enrollmentUnchanged: Bool {
        appLock.biometricDomainState == nil || appLock.biometricDomainState == Biometrics.enrollmentState
    }

    private func submit(_ entered: String) {
        let result = appLock.unlock(pin: entered)
        pin = ""
        switch result {
        case .correct:
            message = nil
            failures = 0
            if appLock.biometricsEnabled, !enrollmentUnchanged {
                // The PIN confirms the new enrollment belongs to the user.
                appLock.setBiometrics(enabled: true, domainState: Biometrics.enrollmentState)
            }
        case .wrong(let attemptsLeft):
            failures += 1
            message = attemptsLeft == 1 ? String(localized: "Wrong PIN. 1 try left before a wait.") : String(localized: "Wrong PIN. \(attemptsLeft) tries left before a wait.")
        case .lockedOut:
            failures += 1
            message = nil
        }
    }

    private func offerBiometricsIfActive() {
        guard UIApplication.shared.applicationState == .active, appLock.isLocked, biometricsOffered != appLock.lockGeneration else { return }
        if appLock.biometricsEnabled, !enrollmentUnchanged {
            message = String(localized: "\(Biometrics.kind?.name ?? "Face ID") changed on this device. Enter your PIN to use it again.")
        }
        guard availableBiometrics != nil else { return }
        biometricsOffered = appLock.lockGeneration
        startBiometrics()
    }

    private func startBiometrics() {
        Task { await unlockWithBiometrics() }
    }

    private func unlockWithBiometrics() async {
        if case .success = await Biometrics.authenticate() {
            appLock.unlockWithBiometrics()
        }
    }
}
