import Charts
import SwiftUI

struct StorageTrendView: View, Equatable {
    let kind: DeveloperStorageKind
    let snapshot: StorageTrendSnapshot
    @State private var period: StorageTrendPeriod = .week

    init(kind: DeveloperStorageKind, snapshot: StorageTrendSnapshot, period: StorageTrendPeriod = .week) {
        self.kind = kind
        self.snapshot = snapshot
        _period = State(initialValue: period)
    }

    var body: some View {
        trend
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.kind == rhs.kind && lhs.snapshot == rhs.snapshot }

    private var trend: some View {
        let end = snapshot.endingAt
        let start = end.addingTimeInterval(-period.duration)
        let series = snapshot.series(for: period)
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text(L10n.tr("Size Trend")).font(.caption.weight(.medium))
                    .help(L10n.tr("As of %@; updated with directory scans", "\(end.formatted())"))
                Spacer(minLength: 4)
                Picker(L10n.tr("Trend period"), selection: $period) {
                    ForEach(StorageTrendPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
                .help(L10n.tr("Last 7 or 30 days"))
                .accessibilityLabel(L10n.tr("%@ trend period", "\(kind.title)"))
            }
            if let latestSizeText = series.latestSizeText {
                HStack {
                    Text(L10n.tr("Latest %@", "\(latestSizeText)"))
                    Spacer(minLength: 4)
                    if let changeText = series.changeText {
                        Text(L10n.tr("Change %@", "\(changeText)"))
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(series.points) { sample in
                    LineMark(x: .value(L10n.tr("Time"), sample.date), y: .value(L10n.tr("Size (MiB)"), Double(sample.bytes) / 1_048_576))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let last = series.points.last {
                    PointMark(x: .value(L10n.tr("Time"), last.date), y: .value(L10n.tr("Size (MiB)"), Double(last.bytes) / 1_048_576))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(22)
                }
            }
            .chartXScale(domain: start...end, range: .plotDimension(padding: 4))
            .chartYScale(domain: 0...series.upperBoundMiB)
            .chartXAxis {
                AxisMarks(values: [start, start.addingTimeInterval(period.duration / 2), end]) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(anchor: value.index == 0 ? .topLeading : value.index == 2 ? .topTrailing : .top) {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month().day()))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let mib = value.as(Double.self) {
                            Text(mib >= 1024 ? String(format: "%.1f GiB", mib / 1024)
                                 : String(format: mib > 0 && mib < 1 ? "%.2f MiB" : "%.0f MiB", mib))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: 110)
            .overlay {
                if series.sampleCount == 0 {
                    Text(L10n.tr("No complete scans yet"))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .accessibilityLabel(L10n.tr("%@ size trend over the last %@", "\(kind.title)", "\(period == .week ? L10n.tr("7 days") : L10n.tr("30 days"))"))
            Text(series.sampleCount == 1 ? L10n.tr("One scan recorded. A curve will appear after more scans.") : L10n.tr("Only complete scans are recorded. Lines connect samples; no measurements exist between scans."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .controlSize(.mini)
    }
}
