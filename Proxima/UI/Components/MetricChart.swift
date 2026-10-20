import Charts
import SwiftUI

struct ChartPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

struct ChartSeries: Identifiable {
    let id: String
    let label: String
    let color: Color
    let points: [ChartPoint]

    /// Builds a series from one rrddata field, optionally transformed (e.g. used / total).
    init(_ label: String, color: Color, from samples: [RRDPoint], value: (RRDPoint) -> Double?) {
        id = label
        self.label = label
        self.color = color
        points = samples.compactMap { sample in value(sample).map { ChartPoint(date: sample.time, value: $0) } }
    }
}

enum ChartUnit {
    case percent, bytes, rate, number

    func format(_ value: Double) -> String {
        switch self {
        case .percent: Format.percent(value)
        case .bytes: Format.bytes(value)
        case .rate: Format.rate(value)
        // Up to two decimals without trailing zeros, so axis labels read 0, 2.5, 5, 10.
        case .number: value.formatted(.number.precision(.fractionLength(0...(value < 10 ? 2 : 0))))
        }
    }
}

/// Area chart of rrddata with a hover readout. One series fills, the rest draw lines.
struct MetricChart: View {
    let title: String
    let series: [ChartSeries]
    var unit: ChartUnit = .number
    var ceiling: Double?
    var timeframe: Timeframe = .hour

    @State private var hover: Date?

    var body: some View {
        Card(title: title) {
            chart
        } accessory: {
            HStack(spacing: 10) {
                ForEach(series) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 7, height: 7)
                        Text(item.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(series) { item in
                ForEach(item.points) { point in
                    AreaMark(x: .value("Time", point.date), y: .value(item.label, point.value),
                             series: .value("Series", item.id), stacking: .unstacked)
                        .foregroundStyle(LinearGradient(colors: [item.color.opacity(0.26), item.color.opacity(0.01)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.date), y: .value(item.label, point.value), series: .value("Series", item.id))
                        .foregroundStyle(item.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let hover {
                RuleMark(x: .value("Time", hover))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        readout(at: hover)
                    }
            }
        }
        .chartXSelection(value: $hover)
        .chartYScale(domain: 0...yMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel { Text(unit.format(value.as(Double.self) ?? 0)).font(.caption2) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: timeFormat).font(.caption2)
            }
        }
        .frame(height: 140)
        .overlay {
            if series.allSatisfy({ $0.points.isEmpty }) {
                Text("No data for this period").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var yMax: Double {
        if let ceiling, ceiling > 0 { return ceiling }
        let peak = series.flatMap(\.points).map(\.value).max() ?? 0
        return peak > 0 ? peak * 1.15 : 1
    }

    private var timeFormat: Date.FormatStyle {
        switch timeframe {
        case .hour: .dateTime.hour().minute()
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day().month(.abbreviated)
        case .year: .dateTime.month(.abbreviated)
        }
    }

    private func readout(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date, format: timeframe == .hour ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute())
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(series) { item in
                if let nearest = item.points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) {
                    HStack(spacing: 5) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.label).foregroundStyle(.secondary)
                        Text(unit.format(nearest.value)).monospacedDigit().fontWeight(.medium)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Glass doesn't composite inside chart annotations; a material reads the same.
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// Hour / Day / Week / Month / Year, plus average vs. maximum.
struct TimeframePicker: View {
    @Binding var timeframe: Timeframe
    @Binding var useMaximum: Bool

    var body: some View {
        HStack(spacing: 12) {
            Picker("Timeframe", selection: $timeframe) {
                ForEach(Timeframe.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            Picker("Consolidation", selection: $useMaximum) {
                Text("Average").tag(false)
                Text("Maximum").tag(true)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }
}
