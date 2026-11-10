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
                Text("体积趋势").font(.caption.weight(.medium))
                    .help("截至 \(end.formatted())；随目录扫描更新")
                Spacer(minLength: 4)
                Picker("趋势时间范围", selection: $period) {
                    ForEach(StorageTrendPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 88)
                .help("最近 7 天或 30 天")
                .accessibilityLabel("\(kind.title)趋势时间范围")
            }
            if let latestSizeText = series.latestSizeText {
                HStack {
                    Text("最近 \(latestSizeText)")
                    Spacer(minLength: 4)
                    if let changeText = series.changeText {
                        Text("变化 \(changeText)")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(series.points) { sample in
                    LineMark(x: .value("时间", sample.date), y: .value("体积 (MiB)", Double(sample.bytes) / 1_048_576))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let last = series.points.last {
                    PointMark(x: .value("时间", last.date), y: .value("体积 (MiB)", Double(last.bytes) / 1_048_576))
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
                    Text("暂无完整扫描记录")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .accessibilityLabel("\(kind.title)最近\(period == .week ? "7 天" : "30 天")体积趋势")
            Text(series.sampleCount == 1 ? "已记录 1 次扫描，后续扫描后形成曲线。" : "仅记录完整扫描；曲线连接采样点，未扫描时段无实测数据。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .controlSize(.mini)
    }
}
