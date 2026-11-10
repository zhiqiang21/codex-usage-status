import Foundation

enum StorageTrendPeriod: String, CaseIterable, Identifiable, Sendable {
    case week, month

    var id: Self { self }
    var title: String {
        switch self {
        case .week: "周"
        case .month: "月"
        }
    }
    var duration: TimeInterval {
        switch self {
        case .week: 7 * 24 * 3600
        case .month: 30 * 24 * 3600
        }
    }
}

struct StorageSizeSample: Codable, Equatable, Identifiable, Sendable {
    let date: Date
    let bytes: Int64
    var id: Date { date }
}

struct StorageSizeHistory: Codable, Equatable, Sendable {
    let path: String
    var samples: [StorageSizeSample]

    func samples(in period: StorageTrendPeriod, endingAt end: Date) -> [StorageSizeSample] {
        let start = end.addingTimeInterval(-period.duration)
        return samples.filter { $0.date >= start && $0.date <= end }
    }

    // Keep the first/latest real measurements per five minutes for a day,
    // and the latest per hour before that. This retains immediate cleanup
    // changes while bounding disk usage. Never interpolate or zero-fill.
    mutating func compact(now: Date) {
        let cutoff = now.addingTimeInterval(-StorageTrendPeriod.month.duration)
        let detailedCutoff = now.addingTimeInterval(-24 * 3600)
        var buckets: [Int64: StorageSizeSample] = [:]
        var firstSamples: [Int64: StorageSizeSample] = [:]
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            guard sample.bytes >= 0, sample.date.timeIntervalSince1970.isFinite,
                  sample.date >= cutoff, sample.date <= now else { continue }
            let interval: TimeInterval = sample.date >= detailedCutoff ? 300 : 3600
            // The two resolutions have separate keys even at the boundary.
            let bucket = Int64(floor(sample.date.timeIntervalSince1970 / interval)) * 2
                + (interval == 300 ? 1 : 0)
            if interval == 300, firstSamples[bucket] == nil { firstSamples[bucket] = sample }
            buckets[bucket] = sample
        }
        let byDate = Dictionary((Array(firstSamples.values) + Array(buckets.values)).map { ($0.date, $0) },
                                uniquingKeysWith: { _, latest in latest })
        samples = byDate.values.sorted { $0.date < $1.date }
    }
}

struct StorageTrendSeries: Sendable {
    static let maximumPointCount = 128

    let points: [StorageSizeSample]
    let sampleCount: Int
    let latestSizeText: String?
    let changeText: String?
    let upperBoundMiB: Double

    init(samples: [StorageSizeSample], period: StorageTrendPeriod, endingAt end: Date) {
        let start = end.addingTimeInterval(-period.duration)
        let visible = samples.filter { $0.date >= start && $0.date <= end }
        sampleCount = visible.count
        latestSizeText = visible.last.map { StorageSizeFormatter.string($0.bytes) }
        if visible.count > 1, let first = visible.first, let last = visible.last {
            let delta = last.bytes - first.bytes
            changeText = (delta > 0 ? "+" : "") + StorageSizeFormatter.string(delta)
        } else {
            changeText = nil
        }
        upperBoundMiB = max(1, Double(visible.lazy.map(\.bytes).max() ?? 0) / 1_048_576 * 1.1)
        points = Self.downsample(visible, start: start, duration: period.duration)
    }

    private static func downsample(_ samples: [StorageSizeSample], start: Date, duration: TimeInterval) -> [StorageSizeSample] {
        guard samples.count > maximumPointCount else { return samples }
        // Two extrema per time bucket, plus both endpoints. Keeping actual
        // samples avoids hiding short-lived growth or inventing average sizes.
        let bucketCount = (maximumPointCount - 2) / 2
        var minima = [Int?](repeating: nil, count: bucketCount)
        var maxima = minima
        for index in 1..<(samples.count - 1) {
            let fraction = samples[index].date.timeIntervalSince(start) / duration
            let bucket = min(bucketCount - 1, max(0, Int(fraction * Double(bucketCount))))
            if minima[bucket].map({ samples[index].bytes < samples[$0].bytes }) ?? true { minima[bucket] = index }
            if maxima[bucket].map({ samples[index].bytes >= samples[$0].bytes }) ?? true { maxima[bucket] = index }
        }
        let indices = Set([0, samples.count - 1] + minima.compactMap { $0 } + maxima.compactMap { $0 })
        return indices.sorted().map { samples[$0] }
    }
}

struct StorageTrendSnapshot: Equatable, Sendable {
    static let empty = StorageTrendSnapshot(samples: [], endingAt: Date())

    let id = UUID()
    let endingAt: Date
    private let week: StorageTrendSeries
    private let month: StorageTrendSeries

    init(samples: [StorageSizeSample], endingAt: Date) {
        self.endingAt = endingAt
        week = StorageTrendSeries(samples: samples, period: .week, endingAt: endingAt)
        month = StorageTrendSeries(samples: samples, period: .month, endingAt: endingAt)
    }

    func series(for period: StorageTrendPeriod) -> StorageTrendSeries {
        switch period {
        case .week: week
        case .month: month
        }
    }

    // Immutable, actor-prepared snapshots keep equality constant-time, so
    // unrelated Store updates do not traverse sample arrays or rebuild Charts.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct StorageHistoryState: Sendable {
    let histories: [DeveloperStorageKind: StorageSizeHistory]
    let trends: [DeveloperStorageKind: StorageTrendSnapshot]
    let revision: Int
    let warning: String?
}

// File reads, encoding, and atomic writes run on this actor, off the MainActor.
actor StorageHistoryRepository {
    private struct Archive: Codable {
        let version: Int
        let histories: [String: StorageSizeHistory]
    }

    private let fileURL: URL?
    private var loaded = false
    private var histories: [DeveloperStorageKind: StorageSizeHistory] = [:]
    private var trends: [DeveloperStorageKind: StorageTrendSnapshot] = [:]
    private var revision = 0
    private var warning: String?
    private var canSave = true

    init(fileURL: URL? = URL.applicationSupportDirectory
        .appendingPathComponent("com.houzhiqiang.CodexUsageStatus", isDirectory: true)
        .appendingPathComponent("storage-history-v1.json")) {
        self.fileURL = fileURL
    }

    func load(now: Date) -> StorageHistoryState {
        if !loaded {
            loaded = true
            if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
                    if archive.version == 1 {
                        for (key, var history) in archive.histories {
                            guard let kind = DeveloperStorageKind(rawValue: key) else { continue }
                            history.compact(now: now)
                            histories[kind] = history
                            trends[kind] = StorageTrendSnapshot(samples: history.samples, endingAt: now)
                        }
                    } else {
                        canSave = false
                        warning = "存储趋势记录版本不受支持，暂不覆盖原文件。"
                    }
                } catch {
                    canSave = false
                    warning = "无法读取存储趋势记录：\(error.localizedDescription) 本次记录仅保留在内存中。"
                }
            }
        }
        return state
    }

    func record(_ snapshot: DeveloperStorageSnapshot, now: Date) -> StorageHistoryState {
        _ = load(now: now)
        // Missing, partial, and failed scans are unknown sizes, not zero usage.
        guard snapshot.isComplete, let bytes = snapshot.allocatedBytes, bytes >= 0,
              snapshot.scannedAt <= now else { return state }
        var history = histories[snapshot.kind] ?? StorageSizeHistory(path: snapshot.path, samples: [])
        if history.path != snapshot.path {
            history = StorageSizeHistory(path: snapshot.path, samples: [])
        }
        history.samples.removeAll { $0.date == snapshot.scannedAt }
        history.samples.append(StorageSizeSample(date: snapshot.scannedAt, bytes: bytes))
        histories[snapshot.kind] = history
        for kind in Array(histories.keys) {
            guard var current = histories[kind] else { continue }
            current.compact(now: now)
            // Keep other categories' prepared snapshots stable unless their
            // retained samples actually changed (for example through expiry).
            if kind == snapshot.kind || current != histories[kind] {
                trends[kind] = StorageTrendSnapshot(samples: current.samples, endingAt: now)
            }
            histories[kind] = current
        }
        revision += 1
        if canSave, let fileURL {
            do {
                let archive = Archive(version: 1, histories: Dictionary(uniqueKeysWithValues:
                    histories.map { ($0.key.rawValue, $0.value) }))
                let data = try JSONEncoder().encode(archive)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                warning = nil
            } catch {
                warning = "无法保存存储趋势记录：\(error.localizedDescription) 本次记录仅保留在内存中。"
            }
        }
        return state
    }

    private var state: StorageHistoryState {
        StorageHistoryState(histories: histories, trends: trends, revision: revision, warning: warning)
    }
}
