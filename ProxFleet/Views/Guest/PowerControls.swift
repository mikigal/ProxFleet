import FleetCore
import PVEKit
import SwiftUI

extension PowerAction {
    var title: LocalizedStringKey {
        switch self {
        case .start: "Start"
        case .shutdown: "Shut Down"
        case .reboot: "Reboot"
        case .stop: "Stop"
        case .reset: "Reset"
        case .pause: "Pause"
        case .resume: "Resume"
        case .hibernate: "Hibernate"
        }
    }

    var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .shutdown: "power"
        case .reboot: "arrow.clockwise"
        case .stop: "stop.fill"
        case .reset: "bolt.fill"
        case .pause: "pause.fill"
        case .resume: "playpause.fill"
        case .hibernate: "moon.zzz.fill"
        }
    }

    func confirmationTitle(_ name: String) -> String {
        switch self {
        case .shutdown: String(localized: "Shut down \(name)?")
        case .reboot: String(localized: "Reboot \(name)?")
        case .stop: String(localized: "Stop \(name)?")
        case .reset: String(localized: "Reset \(name)?")
        case .hibernate: String(localized: "Hibernate \(name)?")
        default: name
        }
    }

    var confirmationMessage: LocalizedStringKey {
        switch self {
        case .shutdown: "The guest operating system is asked to shut down cleanly."
        case .reboot: "The guest operating system is asked to restart."
        case .stop: "Like pulling the power cable. Unsaved data in the guest may be lost."
        case .reset: "Like pressing the reset button. Unsaved data in the guest may be lost."
        case .hibernate: "Memory is saved to disk and the VM stops. Starting it again resumes where it left off."
        default: ""
        }
    }
}

/// Buttons for the power actions available right now. The first actions get a button each, the rest go in a menu.
struct PowerControls: View {
    let actions: [PowerAction]
    let isBusy: Bool
    let onSelect: (PowerAction) -> Void

    private var visible: [PowerAction] { Array(actions.prefix(actions.count > 3 ? 2 : 3)) }
    private var overflow: [PowerAction] { Array(actions.dropFirst(visible.count)) }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(visible) { action in
                Button {
                    onSelect(action)
                } label: {
                    ActionLabel(title: action.title, systemImage: action.systemImage)
                }
                .tint(action == .start || action == .resume ? .green : action.isForceful ? .red : .accentColor)
                .accessibilityIdentifier("power.\(action.rawValue)")
            }
            if !overflow.isEmpty {
                Menu {
                    ForEach(overflow) { action in
                        Button(role: action.isForceful ? .destructive : nil) {
                            onSelect(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                } label: {
                    ActionLabel(title: "More", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("power.more")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .disabled(isBusy)
    }
}

private struct ActionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title3)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
    }
}
