import Charts
import PVEKit
import SwiftUI

enum PerformanceMetric: String, CaseIterable, Identifiable {
    case cpu, load, memory, network, disk
    /// Storages: used space against the total.
    case usage

    var id: String { rawValue }

    /// Metrics with history for guests and for nodes.
    static let guest: [PerformanceMetric] = [.cpu, .memory, .network, .disk]
    static let node: [PerformanceMetric] = [.cpu, .load, .memory, .network]

    var title: LocalizedStringKey {
        switch self {
        case .cpu: "CPU"
        case .load: "Load"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk I/O"
        case .usage: "Usage"
        }
    }
}

extension RRDTimeframe {
    var title: LocalizedStringKey {
        switch self {
        case .hour: "Hour"
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }
}

/// History of one metric. Network and disk show two series: in/read and out/write.
struct PerformanceChart: View {
    let points: [RRDPoint]
    let metric: PerformanceMetric
    let timeframe: RRDTimeframe

    private struct Sample: Identifiable {
        var time: Date
        var series: String
        var value: Double
        var id: String { "\(series)-\(time.timeIntervalSince1970)" }
    }

    private var samples: [Sample] {
        points.flatMap { point -> [Sample] in
            switch metric {
            case .cpu:
                // Nodes also report the time spent waiting for I/O.
                return [
                    point.cpu.map { Sample(time: point.time, series: "CPU", value: $0) },
                    point.ioWait.map { Sample(time: point.time, series: "IO Delay", value: $0) },
                ].compactMap { $0 }
            case .load:
                return point.loadAverage.map { [Sample(time: point.time, series: "Load", value: $0)] } ?? []
            case .memory:
                return point.memoryUsed.map { [Sample(time: point.time, series: "Used", value: $0)] } ?? []
            case .network:
                return [
                    point.networkIn.map { Sample(time: point.time, series: "In", value: $0) },
                    point.networkOut.map { Sample(time: point.time, series: "Out", value: $0) },
                ].compactMap { $0 }
            case .disk:
                return [
                    point.diskRead.map { Sample(time: point.time, series: "Read", value: $0) },
                    point.diskWrite.map { Sample(time: point.time, series: "Write", value: $0) },
                ].compactMap { $0 }
            case .usage:
                return point.storageUsed.map { [Sample(time: point.time, series: "Used", value: $0)] } ?? []
            }
        }
    }

    private var memoryLimit: Double? {
        points.compactMap(\.memoryTotal).max()
    }

    private var storageLimit: Double? {
        points.compactMap(\.storageTotal).max()
    }

    var body: some View {
        if samples.isEmpty {
            ContentUnavailableView("No Data Yet", systemImage: "chart.xyaxis.line", description: Text(metric == .usage
                ? "The server records the usage while the storage is active."
                : "The server records history while the guest or node runs."))
                .frame(height: 180)
        } else {
            Chart(samples) { sample in
                AreaMark(x: .value("Time", sample.time), y: .value("Value", sample.value))
                    .foregroundStyle(by: .value("Series", sample.series))
                    .opacity(0.15)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", sample.time), y: .value("Value", sample.value))
                    .foregroundStyle(by: .value("Series", sample.series))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: yDomain)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(format(number)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: xAxisFormat)
                }
            }
            .chartLegend(Set(samples.map(\.series)).count > 1 ? .visible : .hidden)
            .chartForegroundStyleScale(range: [Color.accentColor, Color.teal])
            .frame(height: 180)
            .accessibilityLabel(Text(metric.title))
        }
    }

    private var yDomain: ClosedRange<Double> {
        switch metric {
        case .cpu:
            return 0...max(samples.map(\.value).max() ?? 0, 0.05) * 1.1
        case .memory:
            return 0...(memoryLimit ?? (samples.map(\.value).max() ?? 1))
        case .usage:
            return 0...max(storageLimit ?? (samples.map(\.value).max() ?? 1), 1)
        case .network, .disk:
            return 0...max(samples.map(\.value).max() ?? 1, 1) * 1.1
        case .load:
            return 0...max(samples.map(\.value).max() ?? 1, 1) * 1.1
        }
    }

    private func format(_ value: Double) -> String {
        switch metric {
        case .cpu: value.formatted(.percent.precision(.fractionLength(0)))
        case .memory: Int64(value).formatted(.byteCount(style: .memory))
        case .usage: value == 0 ? "0" : Int64(value).formatted(.byteCount(style: .file))
        case .network, .disk: Int64(value).formatted(.byteCount(style: .binary)) + "/s"
        case .load: value.formatted(.number.precision(.fractionLength(0...1)))
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch timeframe {
        case .hour, .day: .dateTime.hour().minute()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day().month(.abbreviated)
        case .year: .dateTime.month(.abbreviated)
        }
    }
}
