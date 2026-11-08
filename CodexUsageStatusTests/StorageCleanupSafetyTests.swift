import Foundation
import XCTest
@testable import CodexUsageStatus

@MainActor
final class StorageCleanupSafetyTests: XCTestCase {
    private let runtimeID = "12345678-1234-1234-1234-123456789ABC"
    private let deviceID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private let clock = Date(timeIntervalSince1970: 2_000_000_000)

    private func temporaryHome() throws -> URL {
        let temporaryRoot = try XCTUnwrap(StorageCanonicalPath.resolve(FileManager.default.temporaryDirectory))
        let home = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("StorageCleanupSafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func write(_ url: URL, ageDays: Double? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: 8_192).write(to: url)
        if let ageDays {
            try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: url.path)
        }
    }

    private func asset(_ home: URL) throws -> URL {
        let asset = home.appendingPathComponent("runtime-assets/test.asset")
        try write(asset.appendingPathComponent("AssetData/runtime.dmg"))
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "MobileAssetProperties": ["SimulatorVersion": "27.2", "Build": "24B8117"]
        ], format: .binary, options: 0)
        try info.write(to: asset.appendingPathComponent("Info.plist"))
        return asset
    }

    private func catalog(_ asset: URL, deletable: Bool = true, state: String = "Ready", duplicate: Bool = false, build: String = "24B8117") throws -> Data {
        var records: [String: [String: Any]] = [:]
        for id in duplicate ? [runtimeID, "87654321-4321-4321-4321-CBA987654321"] : [runtimeID] {
            records[id] = ["identifier": id, "path": asset.appendingPathComponent("AssetData").path,
                "parentMountPath": asset.appendingPathComponent("AssetData").path,
                "mountPath": "/mounted-test-runtime", "platformIdentifier": "com.apple.platform.iphonesimulator",
                "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                "version": "27.2", "build": build, "state": state, "deletable": deletable]
        }
        return try JSONSerialization.data(withJSONObject: records)
    }

    private func devices(_ state: String = "Shutdown") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-27-2": [[
            "udid": deviceID, "name": "Test iPhone", "state": state, "isAvailable": true
        ]]]])
    }

    private func runtimeService(_ home: URL, asset: URL, catalog: Data, devices: Data,
                                deleteStatus: Int32 = 0, removeAsset: Bool = true) -> (DeveloperStorageService, StorageTestCommands) {
        let commands = StorageTestCommands { _, arguments in
            if arguments == ["simctl", "runtime", "list", "--json"] {
                let output = FileManager.default.fileExists(atPath: asset.path) ? catalog : Data("{}".utf8)
                return StorageCommandResult(status: 0, output: output, error: Data())
            }
            if arguments.starts(with: ["simctl", "runtime", "delete"]) {
                if deleteStatus == 0, removeAsset { try FileManager.default.removeItem(at: asset) }
                return StorageCommandResult(status: deleteStatus, output: Data(), error: Data())
            }
            return StorageCommandResult(status: 0, output: devices, error: Data())
        }
        return (DeveloperStorageService(home: home, commands: commands,
            runtimeAssetsRoot: asset.deletingLastPathComponent()), commands)
    }

    func testRuntimePreparationAndManagedDeletionUseExactIdentifier() async throws {
        let home = try temporaryHome()
        let asset = try asset(home)
        let (service, commands) = runtimeService(home, asset: asset, catalog: try catalog(asset), devices: try devices())
        let scan = await service.scan(.simulatorRuntimes)
        let candidate = try XCTUnwrap(scan.entries.first)
        XCTAssertTrue(candidate.canClean)
        XCTAssertNil(candidate.manifest) // Monitoring remains lightweight.
        XCTAssertFalse(candidate.allowsSelection)
        do { _ = try await service.clean(candidate); XCTFail("Unprepared monitoring metadata cannot authorize deletion") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path)) }
        let prepared = try await service.prepareCleanup(candidate)
        XCTAssertNotNil(prepared.manifest)
        XCTAssertTrue(prepared.confirmationMessage.contains(runtimeID))
        XCTAssertTrue(prepared.confirmationMessage.contains(deviceID))
        XCTAssertTrue(prepared.confirmationMessage.contains("重新安装"))
        let result = await service.cleanBatch([prepared]) { _ in }
        XCTAssertFalse(result.hasFailures)
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path))
        XCTAssertEqual(commands.invocations.filter { $0.arguments.contains("delete") }.map(\.arguments),
                       [["simctl", "runtime", "delete", runtimeID]])
        XCTAssertFalse(commands.invocations.contains { $0.arguments.contains("shutdown") || $0.executable == "/usr/sbin/lsof" })
    }

    func testRuntimeRequiresUniqueMatchingMetadataAndSafeDeviceStates() async throws {
        for (duplicate, build, deletable, state, deviceState) in [
            (true, "24B8117", true, "Ready", "Shutdown"),
            (false, "wrong-build", true, "Ready", "Shutdown"),
            (false, "24B8117", false, "Ready", "Shutdown"),
            (false, "24B8117", true, "Verifying", "Shutdown"),
            (false, "24B8117", true, "Ready", "Booted"),
            (false, "24B8117", true, "Ready", "Booting"),
            (false, "24B8117", true, "Ready", "Shutting Down"),
            (false, "24B8117", true, "Ready", "Unknown"),
        ] {
            let home = try temporaryHome()
            let asset = try asset(home)
            let (service, commands) = runtimeService(home, asset: asset,
                catalog: try catalog(asset, deletable: deletable, state: state, duplicate: duplicate, build: build),
                devices: try devices(deviceState))
            let scan = await service.scan(.simulatorRuntimes)
            XCTAssertFalse(try XCTUnwrap(scan.entries.first).canClean)
            XCTAssertFalse(commands.invocations.contains { $0.arguments.contains("delete") })
        }
    }

    func testRuntimeToolFailureRetainsDiskMeasurementAndExplainsXcodeFallback() async throws {
        let home = try temporaryHome()
        let asset = try asset(home)
        let service = DeveloperStorageService(home: home, commands: StorageTestCommands(), runtimeAssetsRoot: asset.deletingLastPathComponent())
        let scan = await service.scan(.simulatorRuntimes)
        XCTAssertTrue(scan.isComplete)
        XCTAssertFalse(try XCTUnwrap(scan.entries.first).canClean)
        XCTAssertTrue(scan.notice?.contains("Xcode") == true)
    }

    func testRuntimeDeviceStateChangesAfterConfirmationBlockUninstall() async throws {
        let home = try temporaryHome()
        let asset = try asset(home)
        let data = try catalog(asset)
        let shutdown = try devices()
        let booted = try devices("Booted")
        let reads = StorageTestCounter()
        let commands = StorageTestCommands { _, arguments in
            if arguments == ["simctl", "runtime", "list", "--json"] {
                return StorageCommandResult(status: 0, output: data, error: Data())
            }
            return StorageCommandResult(status: 0, output: reads.next() <= 2 ? shutdown : booted, error: Data())
        }
        let service = DeveloperStorageService(home: home, commands: commands, runtimeAssetsRoot: asset.deletingLastPathComponent())
        let scan = await service.scan(.simulatorRuntimes)
        let prepared = try await service.prepareCleanup(try XCTUnwrap(scan.entries.first))
        let result = await service.cleanBatch([prepared]) { _ in }
        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path))
        XCTAssertFalse(commands.invocations.contains { $0.arguments.contains("delete") })
    }

    func testRuntimeFailureAndResidualAssetsNeverFallBackToRawDeletion() async throws {
        for status: Int32 in [0, 1] {
            let home = try temporaryHome()
            let asset = try asset(home)
            let (service, commands) = runtimeService(home, asset: asset, catalog: try catalog(asset), devices: try devices(),
                deleteStatus: status, removeAsset: false)
            let scan = await service.scan(.simulatorRuntimes)
            let prepared = try await service.prepareCleanup(try XCTUnwrap(scan.entries.first))
            let result = await service.cleanBatch([prepared]) { _ in }
            XCTAssertTrue(result.hasFailures)
            XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path))
            XCTAssertEqual(commands.invocations.filter { $0.arguments.contains("delete") }.count, 1)
            XCTAssertTrue(commands.invocations.allSatisfy { $0.executable == "/usr/bin/xcrun" })
            if status == 1 { XCTAssertTrue(result.message.contains("Xcode")) }
        }
    }

    func testRuntimeManifestChangesAndBatchAttemptsAreRejected() async throws {
        let home = try temporaryHome()
        let asset = try asset(home)
        let (service, commands) = runtimeService(home, asset: asset, catalog: try catalog(asset), devices: try devices())
        let scan = await service.scan(.simulatorRuntimes)
        let prepared = try await service.prepareCleanup(try XCTUnwrap(scan.entries.first))
        let invalidBatch = await service.cleanBatch([prepared, prepared]) { _ in }
        XCTAssertTrue(invalidBatch.hasFailures)
        try write(asset.appendingPathComponent("changed"))
        let changed = await service.cleanBatch([prepared]) { _ in }
        XCTAssertTrue(changed.hasFailures)
        XCTAssertFalse(commands.invocations.contains { $0.arguments.contains("delete") })
    }

    private func codexFixture(_ home: URL) throws -> URL {
        let root = DeveloperStorageKind.codexData.root(in: home)
        for directory in ["codex_apps_server_info", "codex_apps_tools", "remote_plugin_catalog"] {
            try write(root.appendingPathComponent("cache/\(directory)/cached.json"))
        }
        for relative in ["cache/codex_app_directory/keep.json", "cache/bundled_plugin_exclusions/keep.json",
                         "cache/direct.json", "cache/codex_apps_tools/nested/keep.json", "cache/codex_apps_tools/state.sqlite.json",
                         "archived_sessions/keep.jsonl", "generated_images/keep.png", "auth.json", "config.toml", "state.sqlite"] {
            try write(root.appendingPathComponent(relative))
        }
        for (name, age) in [("codex.log", 8.0), ("codex.log.1", 30), ("codex.log.2.gz", 30),
                            ("exact.log", 7), ("recent.log", 1), ("state.sqlite.log", 30), ("state.sqlite-wal", 30), ("other.txt", 30)] {
            try write(root.appendingPathComponent("log/\(name)"), ageDays: age)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cache/codex_apps_tools/link.json"),
            withDestinationURL: root.appendingPathComponent("auth.json"))
        return root
    }

    private func codexService(_ home: URL, commands: any StorageCommandRunning = StorageTestCommands()) -> DeveloperStorageService {
        let date = clock
        return DeveloperStorageService(home: home, commands: commands, now: { date })
    }

    func testCodexCandidatesRespectWhitelistAgeAndProtectedFiles() async throws {
        let home = try temporaryHome()
        _ = try codexFixture(home)
        let service = codexService(home)
        let scan = await service.scan(.codexData)
        let cache = try XCTUnwrap(scan.entries.first { $0.name == "cache" })
        let logs = try XCTUnwrap(scan.entries.first { $0.name == "log" })
        let caches = try await service.cleanupCandidates(in: cache)
        let oldLogs = try await service.cleanupCandidates(in: logs)
        XCTAssertEqual(caches.count, 3)
        XCTAssertTrue(caches.allSatisfy { $0.canClean && $0.manifest?.isSafeFile == true && $0.cleanupAction == .codexFile(.cache) })
        XCTAssertEqual(Set(oldLogs.map(\.name)), Set(["codex.log", "codex.log.1", "codex.log.2.gz"]))
        XCTAssertTrue(oldLogs.allSatisfy { $0.confirmationMessage.contains("排查历史问题") })
        let protected = try XCTUnwrap(scan.entries.first { $0.name == "archived_sessions" })
        do { _ = try await service.cleanupCandidates(in: protected); XCTFail("Protected data cannot be listed for cleanup") }
        catch { XCTAssertFalse(protected.canClean) }
    }

    func testCodexBatchDeletesOnlySelectedFilesAndRetainsParentsAndUserData() async throws {
        let home = try temporaryHome()
        let root = try codexFixture(home)
        let commands = StorageTestCommands()
        let service = codexService(home, commands: commands)
        let scan = await service.scan(.codexData)
        let parent = try XCTUnwrap(scan.entries.first { $0.name == "cache" })
        let files = try await service.cleanupCandidates(in: parent)
        let result = await service.cleanBatch(files) { _ in }
        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        for relative in ["cache", "cache/codex_apps_tools", "cache/bundled_plugin_exclusions/keep.json", "auth.json",
                         "state.sqlite", "generated_images/keep.png", "archived_sessions/keep.jsonl", "log/codex.log"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path), relative)
        }
        XCTAssertEqual(commands.invocations.map(\.arguments), files.map { ["-nP", "--", $0.path] })
    }

    func testCodexFileChangeOccupancyAndIncompleteChecksRevokeDeletion() async throws {
        for mode in ["changed", "occupied", "incomplete", "link"] {
            let home = try temporaryHome()
            let root = try codexFixture(home)
            let commands = StorageTestCommands { _, _ in
                StorageCommandResult(status: mode == "occupied" ? 0 : 1,
                    output: mode == "occupied" ? Data("open".utf8) : Data(),
                    error: mode == "incomplete" ? Data("permission denied".utf8) : Data())
            }
            let service = codexService(home, commands: commands)
            let scan = await service.scan(.codexData)
            let files = try await service.cleanupCandidates(in: XCTUnwrap(scan.entries.first { $0.name == "cache" }))
            let entry = try XCTUnwrap(files.first)
            if mode == "changed" { try Data("changed".utf8).write(to: URL(fileURLWithPath: entry.path)) }
            if mode == "link" {
                try FileManager.default.removeItem(atPath: entry.path)
                try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: root.appendingPathComponent("auth.json").path)
            }
            do { _ = try await service.clean(entry); XCTFail("Unsafe candidate must not be deleted") }
            catch { XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path)) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("auth.json").path))
        }
    }

    func testCodexSymlinkedCacheParentAndForgedActionAreRejected() async throws {
        let home = try temporaryHome()
        let root = try codexFixture(home)
        let service = codexService(home)
        let scan = await service.scan(.codexData)
        let parent = try XCTUnwrap(scan.entries.first { $0.name == "cache" })
        let files = try await service.cleanupCandidates(in: parent)
        var forged = try XCTUnwrap(files.first)
        forged.cleanupAction = .directory
        XCTAssertFalse(forged.canClean)
        do { _ = try await service.clean(forged); XCTFail("Wrong action kind cannot authorize deletion") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: root.path)) }
        let directory = root.appendingPathComponent("cache/codex_apps_tools")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: root.appendingPathComponent("archived_sessions"))
        do { _ = try await service.cleanupCandidates(in: parent); XCTFail("Linked cache parent must be rejected") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("archived_sessions/keep.jsonl").path)) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for storage state")
    }

    func testStoreLoadsCodexCandidatesSelectsFilesAndInvalidatesThemAfterRefresh() async throws {
        let home = try temporaryHome()
        _ = try codexFixture(home)
        let store = DeveloperStorageStore(service: codexService(home), historyRepository: StorageHistoryRepository(fileURL: nil))
        store.refresh(.codexData)
        try await waitUntil { !store.isBusy }
        let parent = try XCTUnwrap(store.snapshots[.codexData]?.entries.first { $0.name == "cache" })
        store.loadCleanupCandidates(parent)
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.cleanupCandidates[parent.id]?.count, 3)
        store.selectAll(.codexData)
        XCTAssertEqual(store.selection.count, 3)
        store.requestSelectedCleanup()
        let request = try XCTUnwrap(store.pendingConfirmation)
        XCTAssertTrue(request.entries.allSatisfy { $0.manifest?.isSafeFile == true })
        store.cancelCleanup()
        store.refresh(.codexData)
        try await waitUntil { !store.isBusy }
        XCTAssertTrue(store.cleanupCandidates.isEmpty)
        XCTAssertTrue(store.selection.isEmpty)
    }

    func testStorePreparesRuntimeManifestAndDoesNotOfferBatchSelection() async throws {
        let home = try temporaryHome()
        let asset = try asset(home)
        let (service, _) = runtimeService(home, asset: asset, catalog: try catalog(asset), devices: try devices())
        let store = DeveloperStorageStore(service: service, historyRepository: StorageHistoryRepository(fileURL: nil))
        store.refresh(.simulatorRuntimes)
        try await waitUntil { !store.isBusy }
        let entry = try XCTUnwrap(store.snapshots[.simulatorRuntimes]?.entries.first)
        store.selectAll(.simulatorRuntimes)
        store.setSelected(true, entry: entry)
        XCTAssertTrue(store.selection.isEmpty)
        store.requestCleanup(entry)
        try await waitUntil { !store.isBusy }
        let request = try XCTUnwrap(store.pendingConfirmation)
        XCTAssertNotNil(request.entries.first?.manifest)
        XCTAssertTrue(store.canClean(try XCTUnwrap(request.entries.first)))
        store.cancelCleanup()
    }
}
