import AppKit
import Darwin
import XCTest
@testable import CodexUsageStatus

struct StorageStubAppResolver: StorageAppResolving {
    let apps: [String: [URL]]
    func installedAppURLs(forBundleIdentifier identifier: String) -> [URL] { apps[identifier] ?? [] }
}

final class StorageTestCommands: StorageCommandRunning, @unchecked Sendable {
    struct Invocation: Sendable { let executable: String; let arguments: [String] }
    private let lock = NSLock()
    private var recorded: [Invocation] = []
    let handler: @Sendable (String, [String]) throws -> StorageCommandResult

    init(handler: @escaping @Sendable (String, [String]) throws -> StorageCommandResult = { _, _ in
        StorageCommandResult(status: 1, output: Data(), error: Data())
    }) { self.handler = handler }

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> StorageCommandResult {
        lock.lock()
        recorded.append(Invocation(executable: executable, arguments: arguments))
        lock.unlock()
        return try handler(executable, arguments)
    }
}

final class DeveloperStorageTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let temporaryRoot = try XCTUnwrap(StorageCanonicalPath.resolve(FileManager.default.temporaryDirectory))
        let home = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("DeveloperStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func makeVersion(_ home: URL, name: String = "17.5 (21F79)", bytes: Int = 8_192) throws -> URL {
        let url = DeveloperStorageKind.deviceSupport.root(in: home).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 42, count: bytes).write(to: url.appendingPathComponent("symbols"))
        return url
    }

    private let udid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    private func deviceJSON(state: String = "Shutdown", isAvailable: Bool? = true) -> Data {
        let availability = isAvailable.map { ",\"isAvailable\":\($0)" } ?? ""
        return Data("""
        {"devices":{"com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[
          {"udid":"\(udid)","name":"Apple Watch","state":"\(state)"\(availability)}
        ]}}
        """.utf8)
    }

    func testMissingAndEmptyDirectoriesAreDistinct() async throws {
        let home = try temporaryHome()
        let service = DeveloperStorageService(home: home, commands: StorageTestCommands())
        let missing = await service.scan(.deviceSupport)
        XCTAssertTrue(missing.isMissing)
        XCTAssertNil(missing.allocatedBytes)
        try FileManager.default.createDirectory(at: DeveloperStorageKind.deviceSupport.root(in: home), withIntermediateDirectories: true)
        let empty = await service.scan(.deviceSupport)
        XCTAssertTrue(empty.isComplete)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertNotNil(empty.allocatedBytes)
    }

    func testMonitoringCategoriesUseTheRequestedRootsAndRemainReadOnly() {
        let home = URL(fileURLWithPath: "/Users/test-user")
        XCTAssertEqual(DeveloperStorageKind.codexData.root(in: home).path, "/Users/test-user/.codex")
        XCTAssertEqual(DeveloperStorageKind.simulatorRuntimes.root(in: home).path,
                       "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime")
        XCTAssertFalse(DeveloperStorageKind.codexData.showsBatchSelection)
        XCTAssertFalse(DeveloperStorageKind.simulatorRuntimes.showsBatchSelection)
    }

    func testCodexMonitoringShowsBreakdownWithoutReadingFileContentsOrKeepingManifests() async throws {
        let home = try temporaryHome()
        let root = DeveloperStorageKind.codexData.root(in: home)
        for name in ["archived_sessions", "generated_images", "sessions"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 42, count: name == "archived_sessions" ? 65_536 : 8_192)
                .write(to: directory.appendingPathComponent("test-data"))
        }
        let auth = root.appendingPathComponent("auth.json")
        try Data("unreadable test content".utf8).write(to: auth)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: auth.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path) }
        let commands = StorageTestCommands()
        let scan = await DeveloperStorageService(home: home, commands: commands).scan(.codexData)
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.entries.count, 4)
        XCTAssertEqual(scan.entries.first?.displayName, "归档会话")
        XCTAssertEqual(scan.entries.first { $0.name == "generated_images" }?.displayName, "生成图片")
        XCTAssertTrue(scan.entries.allSatisfy { $0.manifest == nil && !$0.canClean && $0.modifiedAt != nil })
        XCTAssertTrue(commands.invocations.isEmpty)
    }

    func testRuntimeMonitoringShowsAssetVersionAndDoesNotIncludeOutsideVolumes() async throws {
        let home = try temporaryHome()
        let root = home.appendingPathComponent("runtime-assets")
        let asset = root.appendingPathComponent("test.asset")
        let payload = asset.appendingPathComponent("AssetData")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8_192).write(to: payload.appendingPathComponent("runtime.dmg"))
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "MobileAssetProperties": ["SimulatorVersion": "27.2", "Build": "24B8117"]
        ], format: .binary, options: 0)
        try info.write(to: asset.appendingPathComponent("Info.plist"))
        let outside = home.appendingPathComponent("mounted-volume-data")
        try Data(repeating: 2, count: 1_048_576).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let commands = StorageTestCommands()
        let service = DeveloperStorageService(home: home, commands: commands, runtimeAssetsRoot: root)
        let scan = await service.scan(.simulatorRuntimes)
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.entries.count, 2)
        XCTAssertEqual(scan.entries.first { $0.path == asset.path }?.displayName, "iOS 27.2 (24B8117)")
        XCTAssertLessThan(try XCTUnwrap(scan.allocatedBytes), 1_048_576)
        XCTAssertTrue(scan.entries.allSatisfy { $0.manifest == nil && !$0.canClean })
        XCTAssertFalse(commands.invocations.contains { $0.arguments.contains("delete") })
    }

    func testMissingRuntimeAssetsAreReportedWithoutZeroUsageOrOtherScans() async throws {
        let home = try temporaryHome()
        let commands = StorageTestCommands()
        let scan = await DeveloperStorageService(home: home, commands: commands,
            runtimeAssetsRoot: home.appendingPathComponent("missing-assets")).scan(.simulatorRuntimes)
        XCTAssertTrue(scan.isMissing)
        XCTAssertNil(scan.allocatedBytes)
        XCTAssertTrue(commands.invocations.isEmpty)
    }

    func testMonitoringKindsCannotBeCleanedEvenWithForgedCleanupMetadata() async throws {
        let home = try temporaryHome()
        let version = try makeVersion(home)
        let commands = StorageTestCommands()
        let service = DeveloperStorageService(home: home, commands: commands)
        let scan = await service.scan(.deviceSupport)
        let source = try XCTUnwrap(scan.entries.first)
        for kind in [DeveloperStorageKind.codexData, .simulatorRuntimes] {
            let entry = DeveloperStorageEntry(kind: kind, path: source.path, name: source.name,
                manifest: source.manifest, measuredBytes: source.measuredBytes, modifiedAt: source.modifiedAt,
                issues: [], device: nil, cleanupUnavailableReason: nil)
            XCTAssertFalse(entry.canClean)
            do { _ = try await service.clean(entry); XCTFail("Read-only categories cannot be cleaned") }
            catch { XCTAssertTrue(error.localizedDescription.contains("安全性")) }
            let result = await service.cleanBatch([entry]) { _ in }
            XCTAssertTrue(result.hasFailures)
            XCTAssertTrue(result.snapshots.isEmpty)
        }
        XCTAssertTrue(commands.invocations.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: version.path))
    }

    func testAllocatedSizeAndDescendingSort() async throws {
        let home = try temporaryHome()
        _ = try makeVersion(home)
        let large = try makeVersion(home, name: "18.0 (22A1)", bytes: 1_048_576)
        let scan = await DeveloperStorageService(home: home).scan(.deviceSupport)
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.entries.count, 2)
        XCTAssertEqual(scan.entries.first?.path, large.path)
        let entry = try XCTUnwrap(scan.entries.first)
        let values = try large.appendingPathComponent("symbols").resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        XCTAssertGreaterThanOrEqual(entry.measuredBytes, Int64(try XCTUnwrap(values.totalFileAllocatedSize)))
        XCTAssertTrue(entry.canClean)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(scan.allocatedBytes), scan.entries.reduce(0) { $0 + $1.measuredBytes })
        XCTAssertEqual(StorageSizeFormatter.string(1_073_741_824), "1.00 GiB")
    }

    func testLinksAreNotTraversedAndCannotBeDeleted() async throws {
        let home = try temporaryHome()
        let outside = home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_048_576).write(to: outside.appendingPathComponent("keep"))
        let root = DeveloperStorageKind.deviceSupport.root(in: home)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("17.5 (21F79)"), withDestinationURL: outside)
        let scan = await DeveloperStorageService(home: home).scan(.deviceSupport)
        let entry = try XCTUnwrap(scan.entries.first)
        XCTAssertFalse(entry.canClean)
        XCTAssertLessThan(entry.measuredBytes, 1_048_576)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep").path))
    }

    func testUnknownNamesAndControlCharactersAreReadOnly() async throws {
        let home = try temporaryHome()
        _ = try makeVersion(home, name: "notes")
        _ = try makeVersion(home, name: "17.5 (21F79)\n")
        let scan = await DeveloperStorageService(home: home).scan(.deviceSupport)
        XCTAssertTrue(scan.entries.allSatisfy { !$0.canClean })
        XCTAssertFalse(StoragePathLabel.string("line\nbreak").contains("\n"))
    }

    func testUnreadableRootDoesNotReportZero() async throws {
        let home = try temporaryHome()
        let root = DeveloperStorageKind.deviceSupport.root(in: home)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: root)
        let scan = await DeveloperStorageService(home: home).scan(.deviceSupport)
        XCTAssertFalse(scan.isMissing)
        XCTAssertNil(scan.allocatedBytes)
        XCTAssertFalse(scan.issues.isEmpty)
    }

    func testPermissionErrorsUseStructuredCodesRatherThanLocalizedMessages() {
        XCTAssertTrue(StorageFileAccess.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertTrue(StorageFileAccess.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        XCTAssertTrue(StorageFileAccess.isPermissionDenied(CocoaError(.fileReadNoPermission)))
        let wrapped = NSError(domain: "test", code: 99, userInfo: [NSUnderlyingErrorKey:
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        XCTAssertTrue(StorageFileAccess.isPermissionDenied(wrapped))
        XCTAssertFalse(StorageFileAccess.isPermissionDenied(DeveloperStorageError.unsafeTarget))
        XCTAssertFalse(StorageFileAccess.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        XCTAssertFalse(StorageFileAccess.isPermissionDenied(NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Permission denied"])))
    }

    func testPhysicalTmpPathsAreAcceptedButSymlinkRootsStayReadOnly() async throws {
        // Inspect only metadata for the real system root; scans and cleanup below
        // are restricted to this uniquely named test directory.
        XCTAssertEqual(StorageCanonicalPath.resolve(URL(fileURLWithPath: "/private/tmp")), "/private/tmp")
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("CodexTmpPathTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("old-file")
        try Data([1]).write(to: file)
        let current = Date()
        try FileManager.default.setAttributes([.modificationDate: current.addingTimeInterval(-10 * 86_400)], ofItemAtPath: file.path)
        let commands = StorageTestCommands()
        let service = DeveloperStorageService(home: root, commands: commands, systemTmpRoot: root, now: { current })
        let scan = await service.scan(.systemTmp)
        XCTAssertTrue(scan.isComplete)
        XCTAssertTrue(scan.permissionDeniedPaths.isEmpty)
        let entry = try XCTUnwrap(scan.entries.first)
        XCTAssertTrue(entry.canClean)
        let link = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let linkedService = DeveloperStorageService(home: root, commands: commands, systemTmpRoot: link, now: { current })
        let linkedScan = await linkedService.scan(.systemTmp)
        XCTAssertFalse(linkedScan.isComplete)
        XCTAssertTrue(linkedScan.entries.isEmpty)
        XCTAssertTrue(linkedScan.permissionDeniedPaths.isEmpty)
        try FileManager.default.removeItem(at: link)
        // The root's mtime changed, but a selected single file is unchanged.
        let result = try await service.clean(entry)
        XCTAssertTrue(result.targetRemoved)
    }

    func testPermissionDeniedRootIsRecordedAndCanBeRescannedAfterAccessChanges() async throws {
        guard getuid() != 0 else { throw XCTSkip("Root bypasses directory permissions") }
        let home = try temporaryHome()
        let root = DeveloperStorageKind.appSupport.root(in: home)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        let service = DeveloperStorageService(home: home, commands: StorageTestCommands())
        let denied = await service.scan(.appSupport)
        XCTAssertFalse(denied.isComplete)
        XCTAssertEqual(denied.permissionDeniedPaths, [root.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let allowed = await service.scan(.appSupport)
        XCTAssertTrue(allowed.isComplete)
        XCTAssertTrue(allowed.permissionDeniedPaths.isEmpty)
    }

    func testPermissionFailureIsPartialAndDisablesCleanup() async throws {
        guard getuid() != 0 else { throw XCTSkip("Root bypasses directory permissions") }
        let home = try temporaryHome()
        let version = try makeVersion(home)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: version.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: version.path) }
        let scan = await DeveloperStorageService(home: home).scan(.deviceSupport)
        XCTAssertFalse(scan.isComplete)
        XCTAssertFalse(scan.issues.isEmpty)
        XCTAssertEqual(scan.permissionDeniedPaths, [version.path])
        XCTAssertFalse(try XCTUnwrap(scan.entries.first).canClean)
    }

    func testDescendantChangeRevokesAuthorizationEvenWithSameSize() async throws {
        let home = try temporaryHome()
        let version = try makeVersion(home)
        let commands = StorageTestCommands()
        let service = DeveloperStorageService(home: home, commands: commands)
        let scan = await service.scan(.deviceSupport)
        let entry = try XCTUnwrap(scan.entries.first)
        try Data(repeating: 9, count: 8_192).write(to: version.appendingPathComponent("symbols"))
        do { _ = try await service.clean(entry); XCTFail("Changed target must not be deleted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("变化")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: version.path))
        XCTAssertTrue(commands.invocations.isEmpty)
    }

    func testOpenFilesAndIncompleteOccupancyCheckBlockDeletion() async throws {
        for result in [
            StorageCommandResult(status: 0, output: Data("open file".utf8), error: Data()),
            StorageCommandResult(status: 1, output: Data(), error: Data("permission denied".utf8)),
            StorageCommandResult(status: 2, output: Data(), error: Data()),
        ] {
            let home = try temporaryHome()
            let version = try makeVersion(home)
            let commands = StorageTestCommands { _, _ in result }
            let service = DeveloperStorageService(home: home, commands: commands)
            let scan = await service.scan(.deviceSupport)
            do { _ = try await service.clean(try XCTUnwrap(scan.entries.first)); XCTFail("Must block deletion") }
            catch { XCTAssertTrue(FileManager.default.fileExists(atPath: version.path)) }
        }
    }

    func testSupportDeletionOnlyRemovesSelectedTemporaryVersion() async throws {
        let home = try temporaryHome()
        let selected = try makeVersion(home)
        let retained = try makeVersion(home, name: "18.0 (22A1)")
        let commands = StorageTestCommands()
        let service = DeveloperStorageService(home: home, commands: commands)
        let scan = await service.scan(.deviceSupport)
        let entry = try XCTUnwrap(scan.entries.first { $0.path == selected.path })
        let result = try await service.clean(entry)
        XCTAssertTrue(result.targetRemoved)
        XCTAssertNotNil(result.directoryReduction)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertEqual(commands.invocations.map(\.arguments), [["-nP", "+D", selected.path]])
    }

    func testDescendantLinkIsMeasuredWithoutFollowingAndExternalDataSurvivesCleanup() async throws {
        let home = try temporaryHome()
        let version = try makeVersion(home)
        let outside = home.appendingPathComponent("keep")
        try Data(repeating: 3, count: 1_048_576).write(to: outside)
        try FileManager.default.createSymbolicLink(at: version.appendingPathComponent("link"), withDestinationURL: outside)
        let service = DeveloperStorageService(home: home, commands: StorageTestCommands())
        let scan = await service.scan(.deviceSupport)
        let entry = try XCTUnwrap(scan.entries.first)
        XCTAssertTrue(entry.canClean)
        XCTAssertLessThan(entry.measuredBytes, 1_048_576)
        _ = try await service.clean(entry)
        XCTAssertEqual(try Data(contentsOf: outside).count, 1_048_576)
    }

    func testChangeDuringOccupancyCheckStopsDeletion() async throws {
        let home = try temporaryHome()
        let version = try makeVersion(home)
        let commands = StorageTestCommands { _, _ in
            try Data("new".utf8).write(to: version.appendingPathComponent("changed"))
            return StorageCommandResult(status: 1, output: Data(), error: Data())
        }
        let service = DeveloperStorageService(home: home, commands: commands)
        let scan = await service.scan(.deviceSupport)
        do { _ = try await service.clean(try XCTUnwrap(scan.entries.first)); XCTFail("Must revalidate after lsof") }
        catch { XCTAssertTrue(error.localizedDescription.contains("变化")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: version.path))
    }

    func testOutsideRootCannotBecomeDeletionTarget() async throws {
        let home = try temporaryHome()
        _ = try makeVersion(home)
        let commands = StorageTestCommands()
        let service = DeveloperStorageService(home: home, commands: commands)
        let scan = await service.scan(.deviceSupport)
        let source = try XCTUnwrap(scan.entries.first)
        let forged = DeveloperStorageEntry(kind: source.kind, path: home.path, name: source.name,
            manifest: source.manifest, measuredBytes: source.measuredBytes, modifiedAt: source.modifiedAt,
            issues: [], device: nil, cleanupUnavailableReason: nil)
        do { _ = try await service.clean(forged); XCTFail("Must reject a target outside the allowed root") }
        catch { XCTAssertTrue(commands.invocations.isEmpty) }
    }

    // MARK: - Library management

    private func makeApp(_ home: URL, identifier: String, name: String) throws -> URL {
        let app = home.appendingPathComponent("Applications/\(name).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier,
            "CFBundleExecutable": name, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func testLibraryKindsUseExpectedRootsAndSelection() {
        let home = URL(fileURLWithPath: "/Users/test-user")
        XCTAssertEqual(DeveloperStorageKind.userCaches.root(in: home).path, "/Users/test-user/Library/Caches")
        XCTAssertEqual(DeveloperStorageKind.appSupport.root(in: home).path, "/Users/test-user/Library/Application Support")
        XCTAssertEqual(DeveloperStorageKind.systemTmp.root(in: home).path, "/private/tmp")
        XCTAssertEqual(DeveloperStorageKind.systemTmp.displayPath, "/private/tmp")
        XCTAssertFalse(DeveloperStorageKind.appSupport.showsBatchSelection)
        for kind in [DeveloperStorageKind.userCaches, .systemTmp] {
            XCTAssertTrue(kind.showsBatchSelection)
            XCTAssertTrue(kind.isLibraryManagement)
        }
    }

    func testCachesMatchActualBundlePathsIncludingHelpersAndFailClosedForUnknownApps() async throws {
        let home = try temporaryHome()
        let root = DeveloperStorageKind.userCaches.root(in: home)
        let chrome = try makeApp(home, identifier: "com.google.Chrome", name: "Google Chrome")
        let idleApp = try makeApp(home, identifier: "com.example.IdleApp", name: "Idle App")
        for name in ["com.google.Chrome", "com.example.IdleApp", "com.example.Unknown", "UnknownCache"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4_096).write(to: directory.appendingPathComponent("blob"))
        }
        let resolver = StorageStubAppResolver(apps: ["com.google.Chrome": [chrome], "com.example.IdleApp": [idleApp]])
        // A nested helper alone is enough to protect the parent app's cache.
        for executable in ["Contents/MacOS/Google Chrome", "Contents/Frameworks/Helper.app/Contents/MacOS/Helper"] {
            let processList = Data("\(chrome.path)/\(executable)\n/usr/sbin/syslogd\n".utf8)
            let commands = StorageTestCommands { path, _ in
                path == "/bin/ps" ? StorageCommandResult(status: 0, output: processList, error: Data())
                    : StorageCommandResult(status: 1, output: Data(), error: Data())
            }
            let scan = await DeveloperStorageService(home: home, commands: commands, appResolver: resolver).scan(.userCaches)
            let running = try XCTUnwrap(scan.entries.first { $0.name == "com.google.Chrome" })
            XCTAssertFalse(running.canClean)
            XCTAssertNil(running.manifest)
            XCTAssertEqual(running.cleanupUnavailableReason, "归属应用正在运行，暂不能删除")
            let idle = try XCTUnwrap(scan.entries.first { $0.name == "com.example.IdleApp" })
            XCTAssertTrue(idle.canClean)
            XCTAssertEqual(idle.safetyMark, "符合清理条件")
            XCTAssertTrue(scan.entries.filter { $0.name.contains("Unknown") }.allSatisfy { !$0.canClean && $0.manifest == nil })
            XCTAssertEqual(commands.invocations.filter { $0.executable == "/bin/ps" }.count, 1)
        }
        let failing = StorageTestCommands()
        let fallback = await DeveloperStorageService(home: home, commands: failing, appResolver: resolver).scan(.userCaches)
        XCTAssertTrue(fallback.entries.allSatisfy { !$0.canClean && $0.manifest == nil })
    }

    func testCachesCheckEveryRegisteredInstallationAndValidateBundleIdentifier() async throws {
        let home = try temporaryHome()
        let first = try makeApp(home, identifier: "com.google.Chrome", name: "Chrome First")
        let second = try makeApp(home, identifier: "com.google.Chrome", name: "Chrome Second")
        let wrong = try makeApp(home, identifier: "com.example.Other", name: "Wrong App")
        let root = DeveloperStorageKind.userCaches.root(in: home)
        for name in ["com.google.Chrome", "com.example.Mismatch"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let commands = StorageTestCommands { executable, _ in
            executable == "/bin/ps" ? StorageCommandResult(status: 0,
                output: Data("\(second.path)/Contents/MacOS/Google Chrome\n".utf8), error: Data())
                : StorageCommandResult(status: 1, output: Data(), error: Data())
        }
        let resolver = StorageStubAppResolver(apps: ["com.google.Chrome": [first, second], "com.example.Mismatch": [wrong]])
        let scan = await DeveloperStorageService(home: home, commands: commands, appResolver: resolver).scan(.userCaches)
        XCTAssertEqual(scan.entries.count, 2)
        XCTAssertTrue(scan.entries.allSatisfy { !$0.canClean && $0.manifest == nil })
    }

    func testBatchCacheCleanupQueriesProcessesOnlyAtSafetyCheckpoints() async throws {
        let home = try temporaryHome()
        let app = try makeApp(home, identifier: "com.example.IdleApp", name: "Idle App")
        let otherApp = try makeApp(home, identifier: "com.example.SecondApp", name: "Second App")
        let root = DeveloperStorageKind.userCaches.root(in: home)
        for name in ["com.example.IdleApp", "com.example.SecondApp"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let commands = StorageTestCommands { executable, _ in
            executable == "/bin/ps" ? StorageCommandResult(status: 0, output: Data("/usr/sbin/syslogd\n".utf8), error: Data())
                : StorageCommandResult(status: 1, output: Data(), error: Data())
        }
        let resolver = StorageStubAppResolver(apps: ["com.example.IdleApp": [app], "com.example.SecondApp": [otherApp]])
        let service = DeveloperStorageService(home: home, commands: commands, appResolver: resolver)
        let scan = await service.scan(.userCaches)
        let before = commands.invocations.filter { $0.executable == "/bin/ps" }.count
        let result = await service.cleanBatch(scan.entries) { _ in }
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(result.items.count, 2)
        let after = commands.invocations.filter { $0.executable == "/bin/ps" }.count
        // Two fresh checks per target, then one final snapshot. No pre-cleanup
        // category scan or duplicate validation/process listing per target.
        XCTAssertEqual(after - before, 2 * scan.entries.count + 1)
        XCTAssertEqual(commands.invocations.filter { $0.executable == "/usr/sbin/lsof" }.count, 2)
        XCTAssertTrue(result.measurements.contains { $0.contains("用户缓存占用变化无法完整测量") })
    }

    func testStreamingVerificationRejectsIncompleteEvidenceAndPreservesHardLinks() async throws {
        let home = try temporaryHome()
        let directory = try makeVersion(home)
        try FileManager.default.linkItem(at: directory.appendingPathComponent("symbols"), to: directory.appendingPathComponent("symbols-copy"))
        let commands = StorageTestCommands()
        let service = DeveloperStorageService(home: home, commands: commands)
        let scan = await service.scan(.deviceSupport)
        let entry = try XCTUnwrap(scan.entries.first)
        let manifest = try XCTUnwrap(entry.manifest)
        let badEvidence = [
            StorageManifest(canonicalPath: manifest.canonicalPath, nodes: Array(manifest.nodes.dropLast()), allocatedBytes: manifest.allocatedBytes),
            StorageManifest(canonicalPath: manifest.canonicalPath, nodes: manifest.nodes + [manifest.nodes[0]], allocatedBytes: manifest.allocatedBytes),
            StorageManifest(canonicalPath: manifest.canonicalPath, nodes: manifest.nodes, allocatedBytes: manifest.allocatedBytes + 512)
        ]
        for evidence in badEvidence {
            let forged = entry.withManifest(evidence)
            XCTAssertTrue(forged.canClean)
            do { _ = try await service.clean(forged); XCTFail("Inconsistent evidence must block deletion") }
            catch { XCTAssertTrue(error is DeveloperStorageError) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        }
        XCTAssertTrue(commands.invocations.isEmpty)
        let result = try await service.clean(entry)
        XCTAssertTrue(result.targetRemoved)
        XCTAssertEqual(commands.invocations.count, 1)
    }

    func testCacheDeletionRechecksAppOwnership() async throws {
        let home = try temporaryHome()
        let app = try makeApp(home, identifier: "com.example.IdleApp", name: "Idle App")
        let target = DeveloperStorageKind.userCaches.root(in: home).appendingPathComponent("com.example.IdleApp")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let commands = StorageTestCommands { executable, _ in
            executable == "/bin/ps" ? StorageCommandResult(status: 0, output: Data("/usr/sbin/syslogd\n".utf8), error: Data())
                : StorageCommandResult(status: 1, output: Data(), error: Data())
        }
        let service = DeveloperStorageService(home: home, commands: commands,
            appResolver: StorageStubAppResolver(apps: ["com.example.IdleApp": [app]]))
        let scan = await service.scan(.userCaches)
        let entry = try XCTUnwrap(scan.entries.first)
        XCTAssertTrue(entry.canClean)
        try FileManager.default.removeItem(at: app)
        do { _ = try await service.clean(entry); XCTFail("Unknown app must revoke deletion") }
        catch { XCTAssertTrue(error is DeveloperStorageError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(commands.invocations.contains { $0.executable == "/usr/sbin/lsof" })
    }

    func testCacheDeletionSucceedsWhenIdleButStopsIfAppStartsBeforeFinalCheck() async throws {
        for startsDuringCleanup in [false, true] {
            let home = try temporaryHome()
            let app = try makeApp(home, identifier: "com.example.IdleApp", name: "Idle App")
            let target = DeveloperStorageKind.userCaches.root(in: home).appendingPathComponent("com.example.IdleApp")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data([1]).write(to: target.appendingPathComponent("cache"))
            let counter = StorageTestCounter()
            let commands = StorageTestCommands { executable, _ in
                if executable == "/bin/ps" {
                    let running = counter.next() >= 3 && startsDuringCleanup
                    let path = running ? app.appendingPathComponent("Contents/MacOS/Idle App").path : "/usr/sbin/syslogd"
                    return StorageCommandResult(status: 0, output: Data("\(path)\n".utf8), error: Data())
                }
                return StorageCommandResult(status: 1, output: Data(), error: Data())
            }
            let service = DeveloperStorageService(home: home, commands: commands,
                appResolver: StorageStubAppResolver(apps: ["com.example.IdleApp": [app]]))
            let scan = await service.scan(.userCaches)
            let entry = try XCTUnwrap(scan.entries.first)
            XCTAssertTrue(entry.canClean)
            if startsDuringCleanup {
                do { _ = try await service.clean(entry); XCTFail("A newly started app must block cleanup") }
                catch { XCTAssertTrue(error is DeveloperStorageError) }
                XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
            } else {
                let result = try await service.clean(entry)
                XCTAssertTrue(result.targetRemoved)
                XCTAssertNil(result.directoryReduction)
            }
            XCTAssertEqual(commands.invocations.filter { $0.executable == "/usr/sbin/lsof" }.count, 1)
        }
    }

    func testAppSupportAlwaysRemainsReadOnlyWithoutManifestsOrProcessQueries() async throws {
        let home = try temporaryHome()
        let root = DeveloperStorageKind.appSupport.root(in: home)
        for name in ["com.example.Gone", "com.example.Installed", "NotABundleID"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4_096).write(to: directory.appendingPathComponent("user-data"))
        }
        let app = try makeApp(home, identifier: "com.example.Installed", name: "Installed App")
        let commands = StorageTestCommands()
        let scan = await DeveloperStorageService(home: home, commands: commands,
            appResolver: StorageStubAppResolver(apps: ["com.example.Installed": [app]])).scan(.appSupport)
        XCTAssertEqual(scan.entries.count, 3)
        XCTAssertTrue(scan.entries.allSatisfy { !$0.canClean && !$0.allowsSelection && $0.manifest == nil })
        XCTAssertTrue(scan.isComplete)
        XCTAssertTrue(commands.invocations.isEmpty)
    }

    func testSystemTmpChecksAllDescendantsAndUsesNoProcessQueries() async throws {
        let home = try temporaryHome()
        let tmpRoot = home.appendingPathComponent("tmp")
        let oldFile = tmpRoot.appendingPathComponent("old-report.txt")
        let oldDirectory = tmpRoot.appendingPathComponent("old-session")
        let recentFile = tmpRoot.appendingPathComponent("recent.txt")
        let recentDirectory = tmpRoot.appendingPathComponent("old-parent-recent-child")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recentDirectory, withIntermediateDirectories: true)
        let oldChild = oldDirectory.appendingPathComponent("data")
        let recentChild = recentDirectory.appendingPathComponent("data")
        for file in [oldFile, oldChild, recentFile, recentChild] { try Data([1]).write(to: file) }
        let current = Date()
        let oldDate = current.addingTimeInterval(-10 * 86_400)
        for file in [oldFile, oldChild, oldDirectory, recentDirectory] {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        }
        let commands = StorageTestCommands()
        let service = DeveloperStorageService(home: home, commands: commands, systemTmpRoot: tmpRoot, now: { current })
        let scan = await service.scan(.systemTmp)
        let fileEntry = try XCTUnwrap(scan.entries.first { $0.name == "old-report.txt" })
        let directoryEntry = try XCTUnwrap(scan.entries.first { $0.name == "old-session" })
        XCTAssertTrue(fileEntry.canClean)
        XCTAssertTrue(directoryEntry.canClean)
        XCTAssertFalse(try XCTUnwrap(scan.entries.first { $0.name == "recent.txt" }).canClean)
        XCTAssertFalse(try XCTUnwrap(scan.entries.first { $0.name == "old-parent-recent-child" }).canClean)
        let fileResult = try await service.clean(fileEntry)
        let directoryResult = try await service.clean(directoryEntry)
        XCTAssertTrue(fileResult.targetRemoved)
        XCTAssertTrue(directoryResult.targetRemoved)
        XCTAssertNil(fileResult.directoryReduction)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentChild.path))
        XCTAssertEqual(commands.invocations.map(\.executable), ["/usr/sbin/lsof", "/usr/sbin/lsof"])
        XCTAssertEqual(commands.invocations.map(\.arguments), [["-nP", "--", oldFile.path], ["-nP", "+D", oldDirectory.path]])
    }

    func testSystemTmpBlocksLinksSpecialFilesWritableDirectoriesAndAgeBoundary() async throws {
        let home = try temporaryHome()
        let root = home.appendingPathComponent("tmp")
        let current = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let cutoff = current.addingTimeInterval(-3 * 86_400)
        for name in ["linked", "special", "shared", "boundary"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked/link"), withDestinationURL: home)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("special/pipe").path, 0o600), 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.appendingPathComponent("shared").path)
        for name in ["linked", "special", "shared"] {
            try FileManager.default.setAttributes([.modificationDate: current.addingTimeInterval(-10 * 86_400)], ofItemAtPath: root.appendingPathComponent(name).path)
        }
        try FileManager.default.setAttributes([.modificationDate: cutoff], ofItemAtPath: root.appendingPathComponent("boundary").path)
        let commands = StorageTestCommands()
        let service = DeveloperStorageService(home: home, commands: commands, systemTmpRoot: root, now: { current })
        let scan = await service.scan(.systemTmp)
        XCTAssertEqual(scan.entries.count, 4)
        for entry in scan.entries {
            XCTAssertFalse(entry.canClean, entry.name)
            XCTAssertNil(entry.manifest, entry.name)
        }
        XCTAssertTrue(commands.invocations.isEmpty)
    }

    func testLibraryDeletionRejectsChangedDescendantsAndIncompleteOccupancy() async throws {
        let home = try temporaryHome()
        let root = home.appendingPathComponent("tmp")
        let directory = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("data")
        try Data([1]).write(to: file)
        let current = Date()
        for path in [directory, file] {
            try FileManager.default.setAttributes([.modificationDate: current.addingTimeInterval(-10 * 86_400)], ofItemAtPath: path.path)
        }
        let commands = StorageTestCommands { _, _ in
            StorageCommandResult(status: 1, output: Data(), error: Data("incomplete traversal".utf8))
        }
        let service = DeveloperStorageService(home: home, commands: commands, systemTmpRoot: root, now: { current })
        let scan = await service.scan(.systemTmp)
        let entry = try XCTUnwrap(scan.entries.first)
        XCTAssertTrue(entry.canClean)
        do { _ = try await service.clean(entry); XCTFail("Incomplete occupancy must block deletion") }
        catch { XCTAssertTrue(error is DeveloperStorageError) }
        try Data([2, 3]).write(to: file)
        let second = DeveloperStorageService(home: home, commands: StorageTestCommands(), systemTmpRoot: root, now: { current })
        do { _ = try await second.clean(entry); XCTFail("Changed descendant must block deletion") }
        catch { XCTAssertTrue(error is DeveloperStorageError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testBatchCleansConfirmedCacheTmpAndSupportTargetsTogether() async throws {
        let home = try temporaryHome()
        let support = try makeVersion(home)
        let app = try makeApp(home, identifier: "com.example.IdleApp", name: "Idle App")
        let cache = DeveloperStorageKind.userCaches.root(in: home).appendingPathComponent("com.example.IdleApp")
        let tmpRoot = home.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let file = tmpRoot.appendingPathComponent("old-data")
        try Data([1]).write(to: file)
        let current = Date()
        try FileManager.default.setAttributes([.modificationDate: current.addingTimeInterval(-10 * 86_400)], ofItemAtPath: file.path)
        let commands = StorageTestCommands { executable, _ in
            executable == "/bin/ps" ? StorageCommandResult(status: 0, output: Data("/usr/sbin/syslogd\n".utf8), error: Data())
                : StorageCommandResult(status: 1, output: Data(), error: Data())
        }
        let service = DeveloperStorageService(home: home, commands: commands, systemTmpRoot: tmpRoot,
            appResolver: StorageStubAppResolver(apps: ["com.example.IdleApp": [app]]), now: { current })
        let cacheScan = await service.scan(.userCaches)
        let tmpScan = await service.scan(.systemTmp)
        let supportScan = await service.scan(.deviceSupport)
        let result = await service.cleanBatch(cacheScan.entries + tmpScan.entries + supportScan.entries) { _ in }
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(result.items.count, 3)
        XCTAssertTrue(result.items.allSatisfy(\.removed))
        XCTAssertEqual(result.snapshots.count, 3)
        XCTAssertEqual(result.measurements.filter { $0.contains("所在卷可用空间变化") }.count, 1)
        for target in [support, cache, file] { XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)) }
    }

    func testLibraryActionCannotBypassCodexProtectionOrEscapeRoot() async throws {
        let home = try temporaryHome()
        let codex = DeveloperStorageKind.codexData.root(in: home)
        let sessions = codex.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let current = Date()
        try FileManager.default.setAttributes([.modificationDate: current.addingTimeInterval(-10 * 86_400)], ofItemAtPath: sessions.path)
        let commands = StorageTestCommands()
        // Capture a genuine tree identity, then try it with a forbidden action.
        let scanner = DeveloperStorageService(home: home, commands: commands, systemTmpRoot: codex, now: { current })
        let scan = await scanner.scan(.systemTmp)
        let source = try XCTUnwrap(scan.entries.first)
        XCTAssertTrue(source.canClean)
        let forged = DeveloperStorageEntry(kind: .codexData, path: source.path, name: source.name,
            manifest: source.manifest, measuredBytes: source.measuredBytes, modifiedAt: source.modifiedAt,
            issues: [], device: nil, cleanupUnavailableReason: nil, cleanupAction: .libraryDirectory(.codexData))
        XCTAssertFalse(forged.canClean)
        let service = DeveloperStorageService(home: home, commands: commands)
        do { _ = try await service.clean(forged); XCTFail("Codex sessions must stay protected") }
        catch { XCTAssertTrue(error is DeveloperStorageError) }
        // This forged entry is otherwise cleanable; the root/path guard must reject it.
        let escaped = DeveloperStorageEntry(kind: .systemTmp, path: source.path, name: source.name,
            manifest: source.manifest, measuredBytes: source.measuredBytes, modifiedAt: source.modifiedAt,
            issues: [], device: nil, cleanupUnavailableReason: nil, cleanupAction: .libraryDirectory(.systemTmp))
        XCTAssertTrue(escaped.canClean)
        do { _ = try await service.clean(escaped); XCTFail("Target outside configured tmp must be rejected") }
        catch { XCTAssertTrue(error is DeveloperStorageError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.path))
        XCTAssertTrue(commands.invocations.isEmpty)
    }

    func testDeviceStateChangeRevokesDeletion() async throws {
        let home = try temporaryHome()
        let target = DeveloperStorageKind.simulators.root(in: home).appendingPathComponent(udid)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let shutdown = deviceJSON()
        let booted = deviceJSON(state: "Booted")
        let counter = StorageTestCounter()
        let commands = StorageTestCommands { executable, _ in
            if executable == "/usr/sbin/lsof" {
                return StorageCommandResult(status: 1, output: Data(), error: Data())
            }
            return StorageCommandResult(status: 0, output: counter.next() == 1 ? shutdown : booted, error: Data())
        }
        let service = DeveloperStorageService(home: home, commands: commands)
        let scan = await service.scan(.simulators)
        do { _ = try await service.clean(try XCTUnwrap(scan.entries.first)); XCTFail("Running device must survive") }
        catch { XCTAssertTrue(error.localizedDescription.contains("变化")) }
        XCTAssertFalse(commands.invocations.contains { $0.arguments.contains("delete") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testPlistFallbackDisplaysIdentityButDoesNotAuthorizeDeletion() async throws {
        let home = try temporaryHome()
        let target = DeveloperStorageKind.simulators.root(in: home).appendingPathComponent(udid)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["name": "Saved device", "UDID": udid,
            "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-18-0"], format: .binary, options: 0)
        try data.write(to: target.appendingPathComponent("device.plist"))
        let scan = await DeveloperStorageService(home: home, commands: StorageTestCommands()).scan(.simulators)
        let entry = try XCTUnwrap(scan.entries.first)
        XCTAssertEqual(entry.device?.name, "Saved device")
        XCTAssertEqual(entry.device?.stateTitle, "状态未知")
        XCTAssertFalse(entry.canClean)
    }

    func testSimulatorMetadataAndRunningOrUnknownDeviceDeletionPolicy() async throws {
        let home = try temporaryHome()
        let target = DeveloperStorageKind.simulators.root(in: home).appendingPathComponent(udid)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for (state, available) in ["Shutdown", "Booted", "Booting", "Shutting Down", "Creating", "Unknown"].flatMap({ state in
            [true, false, nil].map { (state, $0) }
        }) {
            let data = deviceJSON(state: state, isAvailable: available)
            let service = DeveloperStorageService(home: home, commands: StorageTestCommands { _, _ in
                StorageCommandResult(status: 0, output: data, error: Data())
            })
            let scan = await service.scan(.simulators)
            let entry = try XCTUnwrap(scan.entries.first)
            XCTAssertEqual(entry.device?.name, "Apple Watch")
            XCTAssertEqual(entry.canClean, state == "Shutdown" || (state == "Creating" && available == false),
                           "\(state), availability: \(String(describing: available))")
        }
        let unavailable = await DeveloperStorageService(home: home, commands: StorageTestCommands()).scan(.simulators)
        XCTAssertNotNil(unavailable.notice)
        XCTAssertTrue(unavailable.isComplete) // Disk measurement remains complete.
        XCTAssertFalse(try XCTUnwrap(unavailable.entries.first).canClean)
    }

    func testSimulatorDeleteUsesExactDeviceAndNeverFallsBackToRawDeletion() async throws {
        for (state, succeeds) in [("Shutdown", true), ("Shutdown", false), ("Creating", true), ("Creating", false)] {
            let home = try temporaryHome()
            let root = DeveloperStorageKind.simulators.root(in: home)
            let target = root.appendingPathComponent(udid)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let data = deviceJSON(state: state, isAvailable: state == "Shutdown")
            let commands = StorageTestCommands { executable, arguments in
                if executable == "/usr/sbin/lsof" { return StorageCommandResult(status: 1, output: Data(), error: Data()) }
                if arguments.contains("delete") {
                    if succeeds { try FileManager.default.removeItem(at: target) }
                    return StorageCommandResult(status: succeeds ? 0 : 1, output: Data(), error: Data())
                }
                return StorageCommandResult(status: 0, output: data, error: Data())
            }
            let service = DeveloperStorageService(home: home, commands: commands)
            let scan = await service.scan(.simulators)
            let entry = try XCTUnwrap(scan.entries.first)
            do {
                let result = try await service.clean(entry)
                XCTAssertTrue(succeeds)
                XCTAssertTrue(result.targetRemoved)
            } catch { XCTAssertFalse(succeeds) }
            let deletions = commands.invocations.filter { $0.arguments.contains("delete") }
            XCTAssertEqual(deletions.count, 1)
            XCTAssertEqual(deletions.first?.arguments, ["simctl", "--set", root.path, "delete", udid])
            XCTAssertEqual(FileManager.default.fileExists(atPath: target.path), !succeeds)
        }
    }

    func testUnavailableCreatingDeviceRemainsProtectedByOccupancyCheck() async throws {
        let home = try temporaryHome()
        let target = DeveloperStorageKind.simulators.root(in: home).appendingPathComponent(udid)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let data = deviceJSON(state: "Creating", isAvailable: false)
        let commands = StorageTestCommands { executable, _ in
            if executable == "/usr/sbin/lsof" {
                return StorageCommandResult(status: 0, output: Data("occupied".utf8), error: Data())
            }
            return StorageCommandResult(status: 0, output: data, error: Data())
        }
        let service = DeveloperStorageService(home: home, commands: commands)
        let scan = await service.scan(.simulators)
        let entry = try XCTUnwrap(scan.entries.first)
        XCTAssertTrue(entry.canClean)
        XCTAssertEqual(entry.device?.stateTitle, "创建未完成")
        do { _ = try await service.clean(entry); XCTFail("An occupied target must survive") }
        catch { XCTAssertTrue(error.localizedDescription.contains("占用")) }
        XCTAssertFalse(commands.invocations.contains { $0.arguments.contains("delete") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testUnavailableCreatingDeviceAvailabilityChangeRevokesDeletion() async throws {
        let home = try temporaryHome()
        let target = DeveloperStorageKind.simulators.root(in: home).appendingPathComponent(udid)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let original = deviceJSON(state: "Creating", isAvailable: false)
        let changed = deviceJSON(state: "Creating", isAvailable: true)
        let counter = StorageTestCounter()
        let commands = StorageTestCommands { executable, _ in
            if executable == "/usr/sbin/lsof" { return StorageCommandResult(status: 1, output: Data(), error: Data()) }
            return StorageCommandResult(status: 0, output: counter.next() == 1 ? original : changed, error: Data())
        }
        let service = DeveloperStorageService(home: home, commands: commands)
        let scan = await service.scan(.simulators)
        do { _ = try await service.clean(try XCTUnwrap(scan.entries.first)); XCTFail("Changed availability must revoke deletion") }
        catch { XCTAssertTrue(error.localizedDescription.contains("变化")) }
        XCTAssertFalse(commands.invocations.contains { $0.arguments.contains("delete") })
    }

    @MainActor
    func testUnavailableCreatingDeviceCanBeSelectedForBatchCleanup() async throws {
        let home = try temporaryHome()
        let target = DeveloperStorageKind.simulators.root(in: home).appendingPathComponent(udid)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let data = deviceJSON(state: "Creating", isAvailable: false)
        let commands = StorageTestCommands { executable, arguments in
            if executable == "/usr/sbin/lsof" { return StorageCommandResult(status: 1, output: Data(), error: Data()) }
            if arguments.contains("delete") {
                try FileManager.default.removeItem(at: target)
                return StorageCommandResult(status: 0, output: Data(), error: Data())
            }
            return StorageCommandResult(status: 0, output: data, error: Data())
        }
        let service = DeveloperStorageService(home: home, commands: commands)
        let store = DeveloperStorageStore(service: service, historyRepository: StorageHistoryRepository(fileURL: nil))
        store.refresh(.simulators)
        for _ in 0..<200 where store.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isBusy)
        store.selectAll(.simulators)
        XCTAssertEqual(store.selection.count, 1)
        store.requestSelectedCleanup()
        let request = try XCTUnwrap(store.pendingConfirmation)
        XCTAssertEqual(request.entries.first?.device?.state, "Creating")
        store.confirmCleanup(request)
        for _ in 0..<200 where store.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.operationFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testRealCommandRunnerDrainsLargeOutputAndHonorsTimeout() async throws {
        let result = try await Task.detached(priority: .utility) {
            try StorageCommandRunner().run(executable: "/usr/bin/head", arguments: ["-c", "200000", "/dev/zero"], timeout: 5)
        }.value
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 200_000)
        let start = Date()
        do {
            _ = try await Task.detached(priority: .utility) {
                try StorageCommandRunner().run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.05)
            }.value
            XCTFail("Command must time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testBatchScansParentOnlyBeforeAndAfterAndKeepsDeviceDeletionSerial() async throws {
        let home = try temporaryHome()
        let root = DeveloperStorageKind.simulators.root(in: home)
        let ids = [udid, "11111111-2222-3333-4444-555555555555"]
        for id in ids {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(id), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-18-0":
            ids.map { ["udid": $0, "name": $0, "state": "Shutdown", "isAvailable": true] as [String: Any] }
        ]])
        let commands = StorageTestCommands { executable, arguments in
            if executable == "/usr/sbin/lsof" { return StorageCommandResult(status: 1, output: Data(), error: Data()) }
            if arguments.contains("delete"), let id = arguments.last {
                try FileManager.default.removeItem(at: root.appendingPathComponent(id))
                return StorageCommandResult(status: 0, output: Data(), error: Data())
            }
            return StorageCommandResult(status: 0, output: data, error: Data())
        }
        let service = DeveloperStorageService(home: home, commands: commands)
        let scan = await service.scan(.simulators)
        let listCountBefore = commands.invocations.filter { $0.arguments.contains("list") }.count
        let progress = StorageBatchProgressRecorder()
        let result = await service.cleanBatch(scan.entries) { await progress.record($0) }
        XCTAssertEqual(result.items.count, 2)
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(result.snapshots.count, 1)
        XCTAssertTrue(result.snapshots[0].entries.isEmpty)
        let listCountAfter = commands.invocations.filter { $0.arguments.contains("list") }.count
        // The pre-cleanup byte measurement needs no simctl. Only the final
        // snapshot and each deletion's live-state check list the devices.
        XCTAssertEqual(listCountAfter - listCountBefore, 1 + ids.count)
        let atomicCommands = commands.invocations.filter {
            $0.executable == "/usr/sbin/lsof" || $0.arguments.contains("delete")
        }
        XCTAssertEqual(atomicCommands.map { $0.executable == "/usr/sbin/lsof" }, [true, false, true, false])
        XCTAssertEqual(result.measurements.filter { $0.contains("所在卷可用空间变化") }.count, 1)
        let updates = await progress.updates
        XCTAssertEqual(updates.map(\.index), [1, 2])
        XCTAssertTrue(updates.allSatisfy { $0.total == 2 })
    }

    func testBatchFailureDoesNotRetryOrPreventOtherConfirmedTargets() async throws {
        let home = try temporaryHome()
        let first = try makeVersion(home)
        let second = try makeVersion(home, name: "18.0 (22A1)")
        let commands = StorageTestCommands { _, arguments in
            let occupied = arguments.last == first.path
            return StorageCommandResult(status: occupied ? 0 : 1, output: occupied ? Data("occupied".utf8) : Data(), error: Data())
        }
        let service = DeveloperStorageService(home: home, commands: commands)
        let scan = await service.scan(.deviceSupport)
        let entries = scan.entries.sorted { $0.path < $1.path }
        let result = await service.cleanBatch(entries) { _ in }
        XCTAssertEqual(result.items.map(\.removed), [false, true])
        XCTAssertTrue(result.hasFailures)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(commands.invocations.filter { $0.arguments.last == first.path }.count, 1)
        XCTAssertEqual(result.snapshots.count, 1)
    }

    func testBatchCanCleanBothGroupsAndMeasuresTheirSharedVolumeOnce() async throws {
        let home = try temporaryHome()
        let support = try makeVersion(home)
        let simulatorRoot = DeveloperStorageKind.simulators.root(in: home)
        let simulator = simulatorRoot.appendingPathComponent(udid)
        try FileManager.default.createDirectory(at: simulator, withIntermediateDirectories: true)
        let data = deviceJSON()
        let commands = StorageTestCommands { executable, arguments in
            if executable == "/usr/sbin/lsof" { return StorageCommandResult(status: 1, output: Data(), error: Data()) }
            if arguments.contains("delete") {
                try FileManager.default.removeItem(at: simulator)
                return StorageCommandResult(status: 0, output: Data(), error: Data())
            }
            return StorageCommandResult(status: 0, output: data, error: Data())
        }
        let service = DeveloperStorageService(home: home, commands: commands)
        let supportScan = await service.scan(.deviceSupport)
        let simulatorScan = await service.scan(.simulators)
        let result = await service.cleanBatch(supportScan.entries + simulatorScan.entries) { _ in }
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(Set(result.snapshots.map(\.kind)), Set([.deviceSupport, .simulators]))
        XCTAssertEqual(result.measurements.filter { $0.contains("所在卷可用空间变化") }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: simulator.path))
    }
}

private actor StorageBatchProgressRecorder {
    private(set) var updates: [StorageCleanupProgress] = []
    func record(_ progress: StorageCleanupProgress) { updates.append(progress) }
}

final class StorageTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private actor StorageDelayedProvider: DeveloperStorageProviding {
    private var continuations: [CheckedContinuation<DeveloperStorageSnapshot, Never>] = []
    private(set) var scanCount = 0
    func scan(_ kind: DeveloperStorageKind) async -> DeveloperStorageSnapshot {
        scanCount += 1
        return await withCheckedContinuation { continuations.append($0) }
    }
    func finish(_ snapshot: DeveloperStorageSnapshot) {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume(returning: snapshot) }
    }
    func clean(_ entry: DeveloperStorageEntry) async throws -> StorageCleanupResult {
        throw DeveloperStorageError.unsafeTarget
    }
}

private actor StorageControlledProvider: DeveloperStorageProviding {
    private var snapshots: [DeveloperStorageKind: DeveloperStorageSnapshot]
    private(set) var scanCount = 0
    private(set) var cleanCount = 0
    private var cleanup: CheckedContinuation<StorageCleanupResult, any Error>?

    init(_ snapshots: [DeveloperStorageKind: DeveloperStorageSnapshot]) { self.snapshots = snapshots }
    func setSnapshot(_ snapshot: DeveloperStorageSnapshot) { snapshots[snapshot.kind] = snapshot }
    func scan(_ kind: DeveloperStorageKind) async -> DeveloperStorageSnapshot {
        scanCount += 1
        return snapshots[kind] ?? DeveloperStorageSnapshot(kind: kind, path: "/missing", entries: [],
            allocatedBytes: nil, scannedAt: Date(), issues: [], isMissing: true, notice: nil)
    }
    func clean(_ entry: DeveloperStorageEntry) async throws -> StorageCleanupResult {
        cleanCount += 1
        let result: StorageCleanupResult = try await withCheckedThrowingContinuation { cleanup = $0 }
        snapshots[entry.kind] = result.snapshot
        return result
    }
    func finishCleanup(_ result: StorageCleanupResult) {
        cleanup?.resume(returning: result)
        cleanup = nil
    }
    func failCleanup() {
        cleanup?.resume(throwing: DeveloperStorageError.targetChanged)
        cleanup = nil
    }
}

@MainActor
final class DeveloperStorageStoreTests: XCTestCase {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for state")
    }

    private func snapshot(date: Date, bytes: Int64? = 100, issues: [String] = []) -> DeveloperStorageSnapshot {
        DeveloperStorageSnapshot(kind: .deviceSupport, path: "/test", entries: [], allocatedBytes: bytes,
            scannedAt: date, issues: issues, isMissing: false, notice: nil)
    }

    func testDuplicateRefreshesAreCoalescedAndFailedRefreshRetainsStaleResult() async throws {
        let provider = StorageDelayedProvider()
        let date = Date()
        let store = DeveloperStorageStore(service: provider, historyRepository: StorageHistoryRepository(fileURL: nil), now: { date })
        store.refresh(.deviceSupport)
        store.refresh(.deviceSupport)
        try await waitUntil { await provider.scanCount == 1 }
        await provider.finish(snapshot(date: date))
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.snapshots[.deviceSupport]?.allocatedBytes, 100)
        XCTAssertFalse(store.isStale(.deviceSupport))
        store.refresh(.deviceSupport)
        try await waitUntil { await provider.scanCount == 2 }
        await provider.finish(snapshot(date: date, bytes: nil, issues: ["denied"]))
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.snapshots[.deviceSupport]?.allocatedBytes, 100)
        XCTAssertTrue(store.isStale(.deviceSupport))
        XCTAssertEqual(store.refreshErrors[.deviceSupport], "denied")
        XCTAssertEqual(store.trendSnapshots[.deviceSupport]?.series(for: .day).points.map(\.bytes), [100])
    }

    func testPermissionGuidanceTracksLatestFailureEvenWhenDisplayingRetainedData() async throws {
        let date = Date()
        let readable = snapshot(date: date)
        let provider = StorageControlledProvider([.deviceSupport: readable])
        let store = DeveloperStorageStore(service: provider, historyRepository: StorageHistoryRepository(fileURL: nil))
        store.refresh(.deviceSupport)
        try await waitUntil { !store.isBusy }
        let denied = DeveloperStorageSnapshot(kind: .deviceSupport, path: "/test", entries: [], allocatedBytes: nil,
            scannedAt: date, issues: ["denied"], isMissing: false, notice: nil, permissionDeniedPaths: ["/test"])
        await provider.setSnapshot(denied)
        store.refresh(.deviceSupport)
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.permissionDeniedKinds, [.deviceSupport])
        XCTAssertEqual(store.snapshots[.deviceSupport]?.allocatedBytes, 100)
        XCTAssertTrue(store.isStale(.deviceSupport))
        let countBefore = await provider.scanCount
        await provider.setSnapshot(readable)
        store.refreshPermissionDeniedDirectories()
        try await waitUntil { !store.isBusy }
        let countAfter = await provider.scanCount
        XCTAssertEqual(countAfter - countBefore, 1)
        XCTAssertTrue(store.permissionDeniedKinds.isEmpty)
        XCTAssertFalse(store.isStale(.deviceSupport))
        store.refreshPermissionDeniedDirectories()
        let finalCount = await provider.scanCount
        XCTAssertEqual(finalCount, countAfter)
    }

    func testFiveMinuteCacheAndIndependentDirectoryRefresh() async throws {
        let date = Date()
        let provider = StorageControlledProvider([.deviceSupport: snapshot(date: date)])
        var now = date
        let store = DeveloperStorageStore(service: provider, historyRepository: StorageHistoryRepository(fileURL: nil), now: { now })
        store.refreshIfNeeded()
        try await waitUntil { !store.isBusy }
        let initial = await provider.scanCount
        XCTAssertEqual(initial, DeveloperStorageKind.allCases.count)
        now = date.addingTimeInterval(299)
        store.refreshIfNeeded()
        XCTAssertFalse(store.isBusy)
        now = date.addingTimeInterval(300)
        store.refreshIfNeeded()
        try await waitUntil { !store.isBusy }
        let refreshed = await provider.scanCount
        XCTAssertGreaterThan(refreshed, initial)
    }

    private func cleanupFixture(names: [String] = ["17.5 (21F79)"]) async throws -> DeveloperStorageSnapshot {
        let temporaryRoot = try XCTUnwrap(StorageCanonicalPath.resolve(FileManager.default.temporaryDirectory))
        let home = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("StorageStoreTests-\(UUID().uuidString)")
        for name in names {
            let version = DeveloperStorageKind.deviceSupport.root(in: home).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return await DeveloperStorageService(home: home).scan(.deviceSupport)
    }

    func testConfirmationSurvivesAlertDismissalAndCleanupIsSerialized() async throws {
        let measured = try await cleanupFixture()
        let provider = StorageControlledProvider([.deviceSupport: measured])
        let store = DeveloperStorageStore(service: provider, historyRepository: StorageHistoryRepository(fileURL: nil))
        store.refresh(.deviceSupport)
        try await waitUntil { !store.isBusy }
        let entry = try XCTUnwrap(store.snapshots[.deviceSupport]?.entries.first)
        XCTAssertTrue(store.canClean(entry))
        store.requestCleanup(entry)
        let request = try XCTUnwrap(store.pendingConfirmation)
        XCTAssertEqual(store.pendingConfirmation?.entries, [entry])
        store.pendingConfirmation = nil // SwiftUI's presentation binding can clear first.
        store.confirmCleanup(request)
        try await waitUntil { await provider.cleanCount == 1 }
        XCTAssertEqual(store.cleaningEntryID, entry.id)
        store.requestCleanup(entry)
        XCTAssertNil(store.pendingConfirmation)
        store.refresh(.deviceSupport)
        let scans = await provider.scanCount
        XCTAssertEqual(scans, 1)
        let after = snapshot(date: Date(), bytes: 0)
        await provider.finishCleanup(StorageCleanupResult(snapshot: after, targetRemoved: true,
            directoryReduction: 100, volumeAvailableChange: 80))
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.snapshots[.deviceSupport]?.allocatedBytes, 0)
        XCTAssertEqual(store.trendSnapshots[.deviceSupport]?.series(for: .day).points.last?.bytes, 0)
        XCTAssertFalse(store.operationFailed)
        XCTAssertNotNil(store.operationMessage)
    }

    func testFailedCleanupRefreshesAndNeverAutomaticallyRetries() async throws {
        let measured = try await cleanupFixture()
        let provider = StorageControlledProvider([.deviceSupport: measured])
        let store = DeveloperStorageStore(service: provider, historyRepository: StorageHistoryRepository(fileURL: nil))
        store.refresh(.deviceSupport)
        try await waitUntil { !store.isBusy }
        let entry = try XCTUnwrap(store.snapshots[.deviceSupport]?.entries.first)
        store.requestCleanup(entry)
        let request = try XCTUnwrap(store.pendingConfirmation)
        store.confirmCleanup(request)
        try await waitUntil { await provider.cleanCount == 1 }
        await provider.failCleanup()
        try await waitUntil { !store.isBusy }
        let cleans = await provider.cleanCount
        let scans = await provider.scanCount
        XCTAssertEqual(cleans, 1)
        XCTAssertEqual(scans, 2)
        XCTAssertTrue(store.operationFailed)
        XCTAssertTrue(store.operationMessage?.contains("重新选择并确认") == true)
        store.confirmCleanup(request)
        XCTAssertNil(store.cleaningEntryID)
    }

    func testCheckboxSelectionSelectAllAndDeselectAllExcludeReadOnlyItems() async throws {
        let measured = try await cleanupFixture(names: ["17.5 (21F79)", "18.0 (22A1)", "notes"])
        let provider = StorageControlledProvider([.deviceSupport: measured])
        let store = DeveloperStorageStore(service: provider, historyRepository: StorageHistoryRepository(fileURL: nil))
        store.refresh(.deviceSupport)
        try await waitUntil { !store.isBusy }
        let entries = try XCTUnwrap(store.snapshots[.deviceSupport]?.entries)
        let readOnly = try XCTUnwrap(entries.first { !$0.canClean })
        store.setSelected(true, entry: readOnly)
        XCTAssertTrue(store.selection.isEmpty)
        store.selectAll(.deviceSupport)
        XCTAssertEqual(store.selection.count, 2)
        XCTAssertTrue(store.canCleanSelection)
        let selected = try XCTUnwrap(store.selectedEntries.first)
        store.setSelected(false, entry: selected)
        XCTAssertEqual(store.selection.count, 1)
        store.setSelected(true, entry: selected)
        XCTAssertEqual(store.selection.count, 2)
        store.deselectAll(.simulators)
        XCTAssertEqual(store.selection.count, 2)
        store.deselectAll(.deviceSupport)
        XCTAssertTrue(store.selection.isEmpty)
        store.selectAll(.deviceSupport)
        store.deselectAll()
        XCTAssertFalse(store.canCleanSelection)
        store.requestSelectedCleanup()
        XCTAssertNil(store.pendingConfirmation)
    }

    func testRefreshRevokesChangedSelectionAndConfirmationDoesNotWiden() async throws {
        let measured = try await cleanupFixture(names: ["17.5 (21F79)", "18.0 (22A1)"])
        let provider = StorageControlledProvider([.deviceSupport: measured])
        let store = DeveloperStorageStore(service: provider, historyRepository: StorageHistoryRepository(fileURL: nil))
        store.refresh(.deviceSupport)
        try await waitUntil { !store.isBusy }
        let entry = try XCTUnwrap(measured.entries.first)
        store.setSelected(true, entry: entry)
        store.requestSelectedCleanup()
        let request = try XCTUnwrap(store.pendingConfirmation)
        store.selectAll(.deviceSupport) // A presented confirmation freezes its exact list.
        XCTAssertEqual(request.entries, [entry])
        XCTAssertEqual(store.selection.count, 1)
        store.cancelCleanup()
        XCTAssertEqual(store.selection.count, 1)
        await provider.setSnapshot(snapshot(date: Date(), bytes: 0))
        store.refresh(.deviceSupport)
        try await waitUntil { !store.isBusy }
        XCTAssertTrue(store.selection.isEmpty)
        store.confirmCleanup(request)
        XCTAssertNil(store.cleaningEntryID)
        let count = await provider.cleanCount
        XCTAssertEqual(count, 0)
    }

    func testBatchUsesOneConfirmationAndKeepsProgressAndCleanupSerial() async throws {
        let measured = try await cleanupFixture(names: ["17.5 (21F79)", "18.0 (22A1)"])
        let provider = StorageControlledProvider([.deviceSupport: measured])
        let store = DeveloperStorageStore(service: provider, historyRepository: StorageHistoryRepository(fileURL: nil))
        store.refresh(.deviceSupport)
        try await waitUntil { !store.isBusy }
        store.selectAll(.deviceSupport)
        store.requestSelectedCleanup()
        let request = try XCTUnwrap(store.pendingConfirmation)
        XCTAssertEqual(request.entries.count, 2)
        store.confirmCleanup(request)
        try await waitUntil { await provider.cleanCount == 1 }
        XCTAssertTrue(store.selection.isEmpty)
        XCTAssertTrue(store.cleanupProgress?.contains("1/2") == true)
        store.refresh(.deviceSupport)
        await provider.failCleanup()
        try await waitUntil { await provider.cleanCount == 2 }
        XCTAssertTrue(store.cleanupProgress?.contains("2/2") == true)
        let after = snapshot(date: Date(), bytes: 0)
        await provider.finishCleanup(StorageCleanupResult(snapshot: after, targetRemoved: true,
            directoryReduction: 100, volumeAvailableChange: 100))
        try await waitUntil { !store.isBusy }
        XCTAssertTrue(store.operationFailed)
        XCTAssertTrue(store.operationMessage?.contains("已清理 1/2") == true)
        XCTAssertNil(store.cleanupProgress)
        let count = await provider.cleanCount
        XCTAssertEqual(count, 2)
    }

    func testDismissingCompletedResultClearsSuccessAndFailureMessages() async throws {
        for fails in [false, true] {
            let measured = try await cleanupFixture()
            let provider = StorageControlledProvider([.deviceSupport: measured])
            let store = DeveloperStorageStore(service: provider, historyRepository: StorageHistoryRepository(fileURL: nil))
            store.refresh(.deviceSupport)
            try await waitUntil { !store.isBusy }
            let entry = try XCTUnwrap(measured.entries.first)
            store.requestCleanup(entry)
            store.confirmCleanup(try XCTUnwrap(store.pendingConfirmation))
            try await waitUntil { await provider.cleanCount == 1 }
            if fails { await provider.failCleanup() }
            else {
                await provider.finishCleanup(StorageCleanupResult(snapshot: snapshot(date: Date(), bytes: 0),
                    targetRemoved: true, directoryReduction: 100, volumeAvailableChange: 100))
            }
            try await waitUntil { !store.isBusy }
            XCTAssertNotNil(store.operationMessage)
            XCTAssertEqual(store.operationFailed, fails)

            store.dismissOperationResult()

            XCTAssertNil(store.operationMessage)
            XCTAssertFalse(store.operationFailed)
            XCTAssertNotNil(store.snapshots[.deviceSupport])
        }
    }

    func testDismissedInFlightResultDoesNotReappearButStillUpdatesStorage() async throws {
        for fails in [false, true] {
            let measured = try await cleanupFixture()
            let provider = StorageControlledProvider([.deviceSupport: measured])
            let store = DeveloperStorageStore(service: provider, historyRepository: StorageHistoryRepository(fileURL: nil))
            store.refresh(.deviceSupport)
            try await waitUntil { !store.isBusy }
            let entry = try XCTUnwrap(measured.entries.first)
            store.requestCleanup(entry)
            store.confirmCleanup(try XCTUnwrap(store.pendingConfirmation))
            try await waitUntil { await provider.cleanCount == 1 }

            store.dismissOperationResult()

            XCTAssertTrue(store.isBusy)
            XCTAssertNotNil(store.cleanupProgress)
            if fails { await provider.failCleanup() }
            else {
                await provider.finishCleanup(StorageCleanupResult(snapshot: snapshot(date: Date(), bytes: 0),
                    targetRemoved: true, directoryReduction: 100, volumeAvailableChange: 100))
            }
            try await waitUntil { !store.isBusy }
            XCTAssertNil(store.operationMessage)
            XCTAssertFalse(store.operationFailed)
            XCTAssertNil(store.cleanupProgress)
            XCTAssertEqual(store.snapshots[.deviceSupport]?.allocatedBytes, fails ? measured.allocatedBytes : 0)

            // A new explicit cleanup has a new result lifetime and can report normally.
            await provider.setSnapshot(measured)
            store.refresh(.deviceSupport)
            try await waitUntil { !store.isBusy }
            store.requestCleanup(entry)
            store.confirmCleanup(try XCTUnwrap(store.pendingConfirmation))
            try await waitUntil { await provider.cleanCount == 2 }
            await provider.finishCleanup(StorageCleanupResult(snapshot: snapshot(date: Date(), bytes: 0),
                targetRemoved: true, directoryReduction: 100, volumeAvailableChange: 100))
            try await waitUntil { !store.isBusy }
            XCTAssertNotNil(store.operationMessage)
        }
    }

    func testPopoverDismissObserverOnlyObservesItsOwnWindowAndDetaches() {
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        let view = UsagePopoverDismissView()
        var dismissals = 0
        view.onDismiss = { dismissals += 1 }
        first.contentView = view
        defer {
            view.stopObserving()
            first.contentView = nil
            second.contentView = nil
        }
        let center = NotificationCenter.default
        center.post(name: NSWindow.didResignKeyNotification, object: second)
        XCTAssertEqual(dismissals, 0)
        center.post(name: NSWindow.didResignKeyNotification, object: first)
        XCTAssertEqual(dismissals, 1)
        center.post(name: NSWindow.willCloseNotification, object: first)
        XCTAssertEqual(dismissals, 2)

        first.contentView = nil
        second.contentView = view
        center.post(name: NSWindow.didResignKeyNotification, object: first)
        XCTAssertEqual(dismissals, 2)
        center.post(name: NSWindow.didResignKeyNotification, object: second)
        XCTAssertEqual(dismissals, 3)

        view.stopObserving()
        center.post(name: NSWindow.willCloseNotification, object: second)
        XCTAssertEqual(dismissals, 3)
    }
}
