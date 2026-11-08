import SwiftUI
import XCTest
@testable import CodexUsageStatus

final class StorageHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ date: Date, bytes: Int64? = 100, kind: DeveloperStorageKind = .deviceSupport,
                          path: String = "/test", issues: [String] = [], missing: Bool = false) -> DeveloperStorageSnapshot {
        DeveloperStorageSnapshot(kind: kind, path: path, entries: [], allocatedBytes: bytes,
            scannedAt: date, issues: issues, isMissing: missing, notice: nil)
    }

    func testPeriodsUseRolling24Hours7DaysAnd30DaysWithoutInventingSamples() {
        let history = StorageSizeHistory(path: "/test", samples: [
            StorageSizeSample(date: now.addingTimeInterval(-31 * 86400), bytes: 10),
            StorageSizeSample(date: now.addingTimeInterval(-30 * 86400), bytes: 20),
            StorageSizeSample(date: now.addingTimeInterval(-7 * 86400), bytes: 30),
            StorageSizeSample(date: now.addingTimeInterval(-86400), bytes: 40),
            StorageSizeSample(date: now, bytes: 50),
            StorageSizeSample(date: now.addingTimeInterval(1), bytes: 60)
        ])
        XCTAssertEqual(history.samples(in: .day, endingAt: now).map(\.bytes), [40, 50])
        XCTAssertEqual(history.samples(in: .week, endingAt: now).map(\.bytes), [30, 40, 50])
        XCTAssertEqual(history.samples(in: .month, endingAt: now).map(\.bytes), [20, 30, 40, 50])
    }

    func testDenseChartsHaveBoundedActualPointsAndPreservePeaksEndpointsAndExactSummary() {
        for period in StorageTrendPeriod.allCases {
            let count = 10_000
            let start = now.addingTimeInterval(-period.duration)
            var samples = (0..<count).map { index in
                StorageSizeSample(date: start.addingTimeInterval(Double(index) * period.duration / Double(count - 1)),
                                  bytes: Int64(1000 + index))
            }
            samples[1234] = StorageSizeSample(date: samples[1234].date, bytes: 1_000_000_000)
            samples[1235] = StorageSizeSample(date: samples[1235].date, bytes: 0)
            let series = StorageTrendSeries(samples: samples, period: period, endingAt: now)

            XCTAssertLessThanOrEqual(series.points.count, StorageTrendSeries.maximumPointCount)
            XCTAssertEqual(series.sampleCount, count)
            XCTAssertEqual(series.points.first, samples.first)
            XCTAssertEqual(series.points.last, samples.last)
            XCTAssertTrue(series.points.contains(samples[1234]), "Short-lived peak must remain visible")
            XCTAssertTrue(series.points.contains(samples[1235]), "Short-lived drop must remain visible")
            XCTAssertEqual(series.points, series.points.sorted { $0.date < $1.date })
            let originals = Dictionary(uniqueKeysWithValues: samples.map { ($0.date, $0.bytes) })
            XCTAssertTrue(series.points.allSatisfy { originals[$0.date] == $0.bytes })
            XCTAssertEqual(Set(series.points.map(\.id)).count, series.points.count)
            XCTAssertEqual(series.latestSizeText, StorageSizeFormatter.string(10_999))
            XCTAssertEqual(series.changeText, "+" + StorageSizeFormatter.string(9999))
            XCTAssertEqual(series.upperBoundMiB, Double(1_000_000_000) / 1_048_576 * 1.1)
        }
    }

    func testSmallChartKeepsAllMeasurementsAndExcludesOutOfRangeSamples() {
        let samples = [
            StorageSizeSample(date: now.addingTimeInterval(-86401), bytes: 999),
            StorageSizeSample(date: now.addingTimeInterval(-86400), bytes: 100),
            StorageSizeSample(date: now, bytes: 0),
            StorageSizeSample(date: now.addingTimeInterval(1), bytes: 999)
        ]
        let series = StorageTrendSeries(samples: samples, period: .day, endingAt: now)
        XCTAssertEqual(series.points, Array(samples[1...2]))
        XCTAssertEqual(series.sampleCount, 2)
        XCTAssertEqual(series.latestSizeText, StorageSizeFormatter.string(0))
        XCTAssertEqual(series.changeText, StorageSizeFormatter.string(-100))
    }

    func testUnrelatedScansAndFailuresReusePreparedChartSnapshots() async throws {
        let repository = StorageHistoryRepository(fileURL: nil)
        let initial = await repository.record(snapshot(now), now: now)
        let original = try XCTUnwrap(initial.trends[.deviceSupport])
        let other = await repository.record(snapshot(now, kind: .simulators), now: now)
        XCTAssertEqual(other.trends[.deviceSupport]?.id, original.id)
        let failed = await repository.record(snapshot(now, bytes: nil, issues: ["denied"]), now: now)
        XCTAssertEqual(failed.trends[.deviceSupport]?.id, original.id)
        XCTAssertEqual(failed.revision, other.revision)
        let updated = await repository.record(snapshot(now.addingTimeInterval(60), bytes: 0), now: now.addingTimeInterval(60))
        XCTAssertNotEqual(updated.trends[.deviceSupport]?.id, original.id)
        XCTAssertEqual(updated.trends[.simulators]?.id, other.trends[.simulators]?.id)
        XCTAssertEqual(updated.trends[.deviceSupport]?.series(for: .day).points.last?.bytes, 0)
    }

    func testCompactionPreservesImmediateChangesAndBoundsHistory() {
        var history = StorageSizeHistory(path: "/test", samples: (0...Int(32 * 86400 / 60)).map { minute in
            StorageSizeSample(date: now.addingTimeInterval(-Double(minute * 60)), bytes: Int64(minute))
        })
        history.samples.append(StorageSizeSample(date: now.addingTimeInterval(-1), bytes: 99))
        history.samples.append(StorageSizeSample(date: now.addingTimeInterval(1), bytes: 500))
        history.samples.append(StorageSizeSample(date: now.addingTimeInterval(-2), bytes: -1))
        history.compact(now: now)
        XCTAssertLessThanOrEqual(history.samples.count, 2 * 289 + 697)
        XCTAssertEqual(history.samples.last?.date, now)
        XCTAssertEqual(history.samples.last?.bytes, 0)
        XCTAssertEqual(Set(history.samples.map(\.date)).count, history.samples.count)
        XCTAssertTrue(history.samples.allSatisfy { $0.date >= now.addingTimeInterval(-30 * 86400) && $0.bytes >= 0 })
        let detailed = history.samples.filter { $0.date >= now.addingTimeInterval(-86400) }
        XCTAssertGreaterThan(detailed.count, 288)
        let compacted = history
        history.compact(now: now)
        XCTAssertEqual(history, compacted)
    }

    func testRecordsOnlyCompleteScansIncludingRealZeroAndKeepsKindsIndependent() async {
        let repository = StorageHistoryRepository(fileURL: nil)
        _ = await repository.record(snapshot(now.addingTimeInterval(-600)), now: now)
        _ = await repository.record(snapshot(now.addingTimeInterval(-500), bytes: nil, issues: ["denied"]), now: now)
        _ = await repository.record(snapshot(now.addingTimeInterval(-400), bytes: 5, issues: ["partial"]), now: now)
        _ = await repository.record(snapshot(now.addingTimeInterval(-300), bytes: nil, missing: true), now: now)
        _ = await repository.record(snapshot(now.addingTimeInterval(-200), bytes: 900, kind: .simulators), now: now)
        _ = await repository.record(snapshot(now.addingTimeInterval(-100), bytes: 0), now: now)
        let state = await repository.record(snapshot(now.addingTimeInterval(1), bytes: 999), now: now)
        XCTAssertEqual(state.histories[.deviceSupport]?.samples.map(\.bytes), [100, 0])
        XCTAssertEqual(state.histories[.simulators]?.samples.map(\.bytes), [900])
        XCTAssertNil(state.warning)
    }

    func testPersistenceReloadAndChangedRootStartsNewSeries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StorageHistoryTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let repository = StorageHistoryRepository(fileURL: file)
        _ = await repository.record(snapshot(now.addingTimeInterval(-60)), now: now)
        let recorded = await repository.record(snapshot(now, bytes: 50), now: now)
        XCTAssertNil(recorded.warning)
        let reloaded = await StorageHistoryRepository(fileURL: file).load(now: now)
        XCTAssertEqual(reloaded.histories, recorded.histories)
        let changed = await repository.record(snapshot(now, bytes: 10, path: "/new-root"), now: now)
        XCTAssertEqual(changed.histories[.deviceSupport]?.path, "/new-root")
        XCTAssertEqual(changed.histories[.deviceSupport]?.samples.map(\.bytes), [10])
        let expired = await StorageHistoryRepository(fileURL: file).load(now: now.addingTimeInterval(31 * 86400))
        XCTAssertTrue(expired.histories[.deviceSupport]?.samples.isEmpty == true)
    }

    func testReadAndWriteFailuresAreVisibleAndMeasurementsRemainAvailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StorageHistoryTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = directory.appendingPathComponent("corrupt.json")
        let original = Data("invalid JSON".utf8)
        try original.write(to: corrupt)
        let corruptRepository = StorageHistoryRepository(fileURL: corrupt)
        let loaded = await corruptRepository.load(now: now)
        XCTAssertNotNil(loaded.warning)
        let state = await corruptRepository.record(snapshot(now), now: now)
        XCTAssertEqual(state.histories[.deviceSupport]?.samples.map(\.bytes), [100])
        XCTAssertNotNil(state.warning)
        XCTAssertEqual(try Data(contentsOf: corrupt), original)

        let blocker = directory.appendingPathComponent("regular-file")
        try Data().write(to: blocker)
        let unwritable = StorageHistoryRepository(fileURL: blocker.appendingPathComponent("history.json"))
        let failedSave = await unwritable.record(snapshot(now), now: now)
        XCTAssertNotNil(failedSave.warning)
        XCTAssertEqual(failedSave.histories[.deviceSupport]?.samples.map(\.bytes), [100])
    }

    @MainActor
    func testChartFitsNarrowPopoverForEmptySingleAndMultipleSamples() throws {
        let end = Date()
        let dense = (0..<1300).map { index in Int64(1_000_000_000 + (index % 31) * 10_000_000) }
        for bytes: [Int64] in [[], [0], [1_000_000, 3_000_000_000, 500_000_000], dense] {
            for period in StorageTrendPeriod.allCases {
                let history = StorageSizeHistory(path: "/test", samples: bytes.enumerated().map {
                    StorageSizeSample(date: end.addingTimeInterval(Double($0.offset - bytes.count)
                        * period.duration / Double(bytes.count + 1)), bytes: $0.element)
                })
                let prepared = StorageTrendSnapshot(samples: history.samples, endingAt: end)
                let view = StorageTrendView(kind: .deviceSupport, snapshot: prepared, period: period)
                    .equatable()
                    .padding(8)
                    .background(Color(nsColor: .windowBackgroundColor))
                let controller = NSHostingController(rootView: view)
                let window = NSWindow(contentViewController: controller)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .aqua)
                let size = controller.sizeThatFits(in: CGSize(width: 292, height: 1000))
                XCTAssertLessThanOrEqual(size.width, 292)
                XCTAssertGreaterThan(size.height, 110)
                XCTAssertLessThan(size.height, 240)
                controller.view.frame = CGRect(origin: .zero, size: size)
                controller.view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                let image = NSImage(size: size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Storage trend \(period.rawValue) \(bytes.count) samples"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.close()
            }
        }
    }
}
