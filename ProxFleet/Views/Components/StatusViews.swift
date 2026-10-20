import PVEKit
import SwiftUI

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

struct PowerStateBadge: View {
    let state: PowerState

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
    }

    private var title: LocalizedStringKey {
        switch state {
        case .running: "Running"
        case .stopped: "Stopped"
        case .paused: "Paused"
        case .unknown: "Unknown"
        }
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .stopped: .secondary
        case .paused: .orange
        case .unknown: .gray
        }
    }
}

struct TagChip: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
    }
}

struct UsageGauge: View {
    let title: LocalizedStringKey
    let fraction: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .font(.caption)
            Gauge(value: min(max(fraction, 0), 1)) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
            .tint(fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .memory))
    }

    static func fraction(_ used: Int64, of total: Int64) -> Double {
        total > 0 ? Double(used) / Double(total) : 0
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2))
    }
}
