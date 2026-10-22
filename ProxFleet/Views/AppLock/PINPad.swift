import LocalAuthentication
import SwiftUI

/// Dots for the digits typed so far and a phone-style keypad, like the system passcode screen.
///
/// Calls `onComplete` once all digits are in; the caller checks the PIN and clears `pin`.
/// Raising `failures` shakes the dots.
struct PINEntryView: View {
    @Binding var pin: String
    let length: Int
    var failures = 0
    var isDisabled = false
    var biometrics: (kind: Biometrics.Kind, action: () -> Void)?
    let onComplete: (String) -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        VStack(spacing: verticalSizeClass == .compact ? 16 : 32) {
            dots
            keypad
        }
        .onChange(of: pin) {
            if pin.count == length {
                onComplete(pin)
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 18) {
            ForEach(0..<length, id: \.self) { index in
                Circle()
                    .strokeBorder(.primary, lineWidth: 1.5)
                    .background(Circle().fill(index < pin.count ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear)))
                    .frame(width: 14, height: 14)
            }
        }
        .keyframeAnimator(initialValue: 0.0, trigger: failures) { content, offset in
            content.offset(x: offset)
        } keyframes: { _ in
            KeyframeTrack {
                for offset in [-14.0, 12, -8, 6, -3, 0] {
                    SpringKeyframe(offset, duration: 0.06)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(pin.count) of \(length) digits entered")
        .accessibilityIdentifier("pin.dots")
    }

    private var keypad: some View {
        let size: CGFloat = verticalSizeClass == .compact ? 58 : 76
        return Grid(horizontalSpacing: 24, verticalSpacing: verticalSizeClass == .compact ? 10 : 16) {
            ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { digit in
                        DigitButton(digit: digit, size: size) { type(digit) }
                    }
                }
            }
            GridRow {
                if let biometrics {
                    Button(action: biometrics.action) {
                        Image(systemName: biometrics.kind.systemImage)
                            .font(.title)
                            .frame(width: size, height: size)
                    }
                    .accessibilityLabel(biometrics.kind.name)
                    .accessibilityIdentifier("pin.biometrics")
                } else {
                    Color.clear.frame(width: size, height: size)
                }
                DigitButton(digit: "0", size: size) { type("0") }
                Button {
                    pin.removeLast()
                } label: {
                    Image(systemName: "delete.backward")
                        .font(.title2)
                        .frame(width: size, height: size)
                }
                .opacity(pin.isEmpty ? 0 : 1)
                .disabled(pin.isEmpty)
                .accessibilityLabel("Delete")
                .accessibilityIdentifier("pin.delete")
            }
        }
        .foregroundStyle(.primary)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }

    private func type(_ digit: String) {
        guard pin.count < length else { return }
        pin.append(digit)
    }
}

private struct DigitButton: View {
    let digit: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(digit)
                .font(.system(size: size * 0.42, weight: .regular, design: .rounded))
                .frame(width: size, height: size)
                .background(.fill.tertiary, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pin.\(digit)")
    }
}

/// The device's face or fingerprint check, offered once the app lock has a PIN.
enum Biometrics {
    enum Kind {
        case faceID, touchID, opticID

        var name: String {
            switch self {
            case .faceID: String(localized: "Face ID")
            case .touchID: String(localized: "Touch ID")
            case .opticID: String(localized: "Optic ID")
            }
        }

        var systemImage: String {
            switch self {
            case .faceID: "faceid"
            case .touchID: "touchid"
            case .opticID: "opticid"
            }
        }
    }

    enum Failure: Error {
        case cancelled
        case unavailable(String)
    }

    /// The sensor this device has, even when nothing is enrolled yet.
    static var kind: Kind? {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return nil
        }
    }

    /// Changes whenever faces or fingerprints are added or removed.
    static var enrollmentState: Data? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return context.domainState.biometry.stateHash
    }

    /// Asks the system to check the user. Returns the enrollment state it checked against.
    static func authenticate() async -> Result<Data?, Failure> {
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Enter PIN")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .failure(.unavailable(error?.localizedDescription ?? String(localized: "Biometric authentication is not available.")))
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: String(localized: "Unlock ProxFleet"))
            return .success(context.domainState.biometry.stateHash)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .userFallback].contains(error.code) {
            return .failure(.cancelled)
        } catch {
            return .failure(.unavailable(error.localizedDescription))
        }
    }
}
