import FleetCore
import SwiftUI

/// App-wide settings, opened from the server list.
struct SettingsView: View {
    @Environment(AppLock.self) private var appLock
    @Environment(\.dismiss) private var dismiss
    @State private var flow: PINFlowView.Purpose?
    private let biometrics = Biometrics.kind

    var body: some View {
        NavigationStack {
            Form {
                security
                about
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
            .sheet(item: $flow) { purpose in
                PINFlowView(purpose: purpose)
            }
        }
    }

    private var security: some View {
        Section {
            Toggle("App Lock", isOn: Binding(get: { appLock.isEnabled }, set: { flow = $0 ? .enable : .disable }))
                .accessibilityIdentifier("settings.appLock")
            if appLock.isEnabled {
                if let biometrics {
                    Toggle(biometrics.name, isOn: Binding(get: { appLock.biometricsEnabled }, set: { enabled in
                        if enabled {
                            flow = .enableBiometrics
                        } else {
                            appLock.setBiometrics(enabled: false, domainState: nil)
                        }
                    }))
                    .accessibilityIdentifier("settings.biometrics")
                }
                Picker("Require PIN", selection: Bindable(appLock).autoLockDelay) {
                    ForEach(AppLock.AutoLockDelay.allCases, id: \.self) { delay in
                        Text(delay.title).tag(delay)
                    }
                }
                .accessibilityIdentifier("settings.autoLock")
                Button("Change PIN") { flow = .change }
                    .accessibilityIdentifier("settings.changePIN")
            }
        } header: {
            Text("Security")
        } footer: {
            if appLock.isEnabled {
                Text("A PIN is asked whenever ProxFleet opens after being in the background for the chosen time. Turning the lock off, changing the PIN or turning on \(biometrics?.name ?? "Face ID") needs the current PIN.")
            } else {
                Text("Ask for a PIN whenever ProxFleet opens. \(biometrics.map { "\($0.name) can be used once a PIN is set." } ?? "")")
            }
        }
    }

    private var about: some View {
        Section("About") {
            LabeledContent("Version", value: Self.version)
            LabeledContent("License", value: "GPL-3.0")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

extension AppLock.AutoLockDelay {
    var title: LocalizedStringKey {
        switch self {
        case .immediately: "Immediately"
        case .oneMinute: "After 1 Minute"
        case .fiveMinutes: "After 5 Minutes"
        case .fifteenMinutes: "After 15 Minutes"
        }
    }
}

/// Sets, checks or changes the PIN for a settings change.
struct PINFlowView: View {
    enum Purpose: String, Identifiable {
        case enable, disable, change, enableBiometrics
        var id: String { rawValue }
    }

    private enum Step: Hashable {
        case verify
        case choose
        case confirm(String)
    }

    let purpose: Purpose
    @Environment(AppLock.self) private var appLock
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step
    @State private var length: AppLock.PINLength
    @State private var pin = ""
    @State private var failures = 0
    @State private var message: String?
    @State private var isCheckingBiometrics = false

    init(purpose: Purpose) {
        self.purpose = purpose
        _step = State(initialValue: purpose == .enable ? .choose : .verify)
        _length = State(initialValue: .six)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    status
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 36, alignment: .top)
                        .accessibilityIdentifier("pinFlow.message")
                }
                .padding(.horizontal)
                // Keeps its space in the other steps, so the keypad does not jump.
                Picker("PIN Length", selection: $length) {
                    Text("4 Digits").tag(AppLock.PINLength.four)
                    Text("6 Digits").tag(AppLock.PINLength.six)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .opacity(step == .choose ? 1 : 0)
                .disabled(step != .choose)
                .accessibilityHidden(step != .choose)
                .accessibilityIdentifier("pinFlow.length")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    PINEntryView(
                        pin: $pin,
                        length: currentLength,
                        failures: failures,
                        isDisabled: isCheckingBiometrics || (step == .verify && (appLock.lockedOutUntil ?? .distantPast) > context.date),
                        onComplete: submit
                    )
                }
                .id(step)
                Spacer()
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .onAppear { length = appLock.isEnabled ? appLock.pinLength : .six }
            .onChange(of: length) { pin = "" }
        }
    }

    private var currentLength: Int {
        switch step {
        case .verify: appLock.pinLength.rawValue
        case .choose: length.rawValue
        case .confirm(let first): first.count
        }
    }

    private var navigationTitle: LocalizedStringKey {
        switch purpose {
        case .enable: "Turn On App Lock"
        case .disable: "Turn Off App Lock"
        case .change: "Change PIN"
        case .enableBiometrics: "Turn On \(Biometrics.kind?.name ?? "Face ID")"
        }
    }

    private var title: LocalizedStringKey {
        switch step {
        case .verify: "Enter Your Current PIN"
        case .choose: purpose == .change ? "Choose a New PIN" : "Choose a PIN"
        case .confirm: "Enter the PIN Again"
        }
    }

    @ViewBuilder
    private var status: some View {
        if step == .verify, let until = appLock.lockedOutUntil, until > .now {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, until.timeIntervalSince(context.date))
                Text("Too many wrong PINs. Try again in \(Duration.seconds(remaining.rounded(.up)).formatted(.time(pattern: .minuteSecond))).")
                    .foregroundStyle(.red)
            }
        } else if let message {
            Text(message)
                .foregroundStyle(.red)
        } else if step == .choose {
            Text("You will need it to open ProxFleet.")
                .foregroundStyle(.secondary)
        } else {
            Text(" ")
        }
    }

    private func submit(_ entered: String) {
        pin = ""
        switch step {
        case .verify:
            switch appLock.check(entered) {
            case .correct:
                message = nil
                verified()
            case .wrong(let attemptsLeft):
                failures += 1
                message = attemptsLeft == 1 ? String(localized: "Wrong PIN. 1 try left before a wait.") : String(localized: "Wrong PIN. \(attemptsLeft) tries left before a wait.")
            case .lockedOut:
                failures += 1
                message = nil
            }
        case .choose:
            message = nil
            step = .confirm(entered)
        case .confirm(let first):
            guard entered == first else {
                failures += 1
                message = String(localized: "The PINs did not match. Try again.")
                step = .choose
                return
            }
            if purpose == .change {
                appLock.changePIN(to: entered)
            } else {
                appLock.enable(pin: entered)
            }
            dismiss()
        }
    }

    private func verified() {
        switch purpose {
        case .enable, .change:
            step = .choose
        case .disable:
            appLock.disable()
            dismiss()
        case .enableBiometrics:
            isCheckingBiometrics = true
            Task {
                let result = await Biometrics.authenticate()
                isCheckingBiometrics = false
                switch result {
                case .success(let state):
                    appLock.setBiometrics(enabled: true, domainState: state)
                    dismiss()
                case .failure(.cancelled):
                    dismiss()
                case .failure(.unavailable(let reason)):
                    message = reason
                }
            }
        }
    }
}
