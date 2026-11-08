import Darwin
import Foundation

protocol DeveloperStorageProviding: Sendable {
    func scan(_ kind: DeveloperStorageKind) async -> DeveloperStorageSnapshot
    func clean(_ entry: DeveloperStorageEntry) async throws -> StorageCleanupResult
    func cleanBatch(_ entries: [DeveloperStorageEntry], progress: @escaping @Sendable (StorageCleanupProgress) async -> Void) async -> StorageBatchCleanupResult
    func prepareCleanup(_ entry: DeveloperStorageEntry) async throws -> DeveloperStorageEntry
    func cleanupCandidates(in parent: DeveloperStorageEntry) async throws -> [DeveloperStorageEntry]
}

// Providers that implement single-item cleanup (including test providers) can
// participate in a batch. The filesystem service overrides this to avoid N full
// parent-directory scans and to measure shared volumes only once.
extension DeveloperStorageProviding {
    func prepareCleanup(_ entry: DeveloperStorageEntry) async throws -> DeveloperStorageEntry {
        guard entry.canClean else { throw DeveloperStorageError.unsafeTarget }
        return entry
    }
    func cleanupCandidates(in parent: DeveloperStorageEntry) async throws -> [DeveloperStorageEntry] {
        throw DeveloperStorageError.unsafeTarget
    }
    func cleanBatch(_ entries: [DeveloperStorageEntry], progress: @escaping @Sendable (StorageCleanupProgress) async -> Void) async -> StorageBatchCleanupResult {
        var snapshots: [DeveloperStorageKind: DeveloperStorageSnapshot] = [:]
        var items: [StorageBatchItemResult] = []
        for (index, entry) in entries.enumerated() {
            await progress(StorageCleanupProgress(entry: entry, index: index + 1, total: entries.count))
            do {
                let result = try await clean(entry)
                snapshots[entry.kind] = result.snapshot
                items.append(StorageBatchItemResult(path: entry.path, removed: result.targetRemoved, message: result.message))
            } catch {
                items.append(StorageBatchItemResult(path: entry.path, removed: false,
                    message: "清理未完成：\(error.localizedDescription)\n如需重试，请重新选择并确认条目。"))
            }
        }
        for kind in Set(entries.map(\.kind)) {
            snapshots[kind] = await scan(kind)
        }
        return StorageBatchCleanupResult(snapshots: Array(snapshots.values), items: items, measurements: [])
    }
}

struct DeveloperStorageService: DeveloperStorageProviding {
    let home: URL
    let commands: any StorageCommandRunning
    private let runtimeAssetsRoot: URL
    private let scanQueue = DispatchQueue(label: "com.houzhiqiang.CodexUsageStatus.storage-scan", qos: .utility)
    private let now: @Sendable () -> Date

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, commands: any StorageCommandRunning = StorageCommandRunner(),
         runtimeAssetsRoot: URL = DeveloperStorageKind.simulatorRuntimes.root(in: FileManager.default.homeDirectoryForCurrentUser),
         now: @escaping @Sendable () -> Date = Date.init) {
        self.home = home.standardizedFileURL
        self.commands = commands
        self.runtimeAssetsRoot = runtimeAssetsRoot.standardizedFileURL
        self.now = now
    }

    private func rootURL(for kind: DeveloperStorageKind) -> URL {
        kind == .simulatorRuntimes ? runtimeAssetsRoot : kind.root(in: home)
    }

    func scan(_ kind: DeveloperStorageKind) async -> DeveloperStorageSnapshot {
        // Several categories can be requested together. Serialize filesystem
        // walks so opening the panel does not create competing large scans.
        await withCheckedContinuation { continuation in
            scanQueue.async { continuation.resume(returning: scanSynchronously(kind)) }
        }
    }

    func clean(_ entry: DeveloperStorageEntry) async throws -> StorageCleanupResult {
        try await Task.detached(priority: .utility) { try cleanSynchronously(entry) }.value
    }

    func cleanBatch(_ entries: [DeveloperStorageEntry], progress: @escaping @Sendable (StorageCleanupProgress) async -> Void) async -> StorageBatchCleanupResult {
        await Task.detached(priority: .utility) { await cleanBatchOnWorker(entries, progress: progress) }.value
    }

    func prepareCleanup(_ entry: DeveloperStorageEntry) async throws -> DeveloperStorageEntry {
        try await withCheckedThrowingContinuation { continuation in
            scanQueue.async {
                do {
                    guard case .runtime = entry.cleanupAction else {
                        guard entry.canClean else { throw DeveloperStorageError.unsafeTarget }
                        continuation.resume(returning: entry)
                        return
                    }
                    let target = try self.validateRuntimePath(entry)
                    try self.revalidateRuntime(entry)
                    let tree = self.scanTree(target, device: try self.identity(target).device)
                    guard let manifest = tree.manifest, manifest.isSafeDirectory else { throw DeveloperStorageError.unsafeTarget }
                    guard manifest.allocatedBytes == entry.measuredBytes, manifest.root?.modifiedAt == entry.modifiedAt else {
                        throw DeveloperStorageError.targetChanged
                    }
                    continuation.resume(returning: entry.withManifest(manifest))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func cleanupCandidates(in parent: DeveloperStorageEntry) async throws -> [DeveloperStorageEntry] {
        try await withCheckedThrowingContinuation { continuation in
            scanQueue.async {
                do { continuation.resume(returning: try self.codexCleanupCandidates(parent)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private struct TreeScan {
        var nodes: [StorageNodeIdentity] = []
        var issues: [String] = []
        var bytes: Int64 = 0
        var rootIdentity: StorageNodeIdentity?
        var rootContribution: Int64 = 0

        var manifest: StorageManifest? {
            guard issues.isEmpty, let root = nodes.first else { return nil }
            return StorageManifest(canonicalPath: URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path,
                                   nodes: nodes, allocatedBytes: bytes)
        }
    }

    private func scanSynchronously(_ kind: DeveloperStorageKind) -> DeveloperStorageSnapshot {
        let root = rootURL(for: kind)
        var issues: [String] = []
        var entries: [DeveloperStorageEntry] = []
        var bytes: Int64?
        var missing = false
        var notice: String?
        do {
            let rootIdentity = try identity(root)
            guard rootIdentity.isDirectory, !rootIdentity.isSymbolicLink, !rootIdentity.isMountPoint,
                  root.resolvingSymlinksInPath().path == root.path else {
                throw DeveloperStorageError.unsafeTarget
            }
            // Preserve the parent's URL spelling. contentsOfDirectory(at:) may
            // return /private/var children for a /var parent on macOS.
            let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .sorted().map { root.appendingPathComponent($0) }
            var devices: [String: SimulatorStorageDevice] = [:]
            var runtimes: [StorageRuntimeInfo] = []
            if kind == .simulators {
                do { devices = try simulatorDevices(root: root) }
                catch { notice = "无法核实模拟器状态，删除已禁用：\(error.localizedDescription)" }
            }
            if kind == .simulatorRuntimes {
                do {
                    runtimes = try runtimeInfos()
                    devices = try simulatorDevices(root: rootURL(for: .simulators))
                } catch { notice = "无法核实运行时，卸载已禁用；可在 Xcode 中管理。\(error.localizedDescription)" }
            }
            var seen = Set<String>()
            bytes = rootIdentity.allocatedBytes
            seen.insert(inodeKey(rootIdentity))
            for child in children {
                let tree = scanTree(child, device: rootIdentity.device, captureManifest: kind.showsBatchSelection, rootInodes: &seen)
                let manifest = tree.manifest
                bytes = (bytes ?? 0) + tree.rootContribution
                issues.append(contentsOf: tree.issues)
                let device = devices[child.lastPathComponent] ?? (kind == .simulators ? deviceFromPlist(child) : nil)
                let authoritative = devices[child.lastPathComponent]
                let asset = kind == .simulatorRuntimes ? runtimeAssetMetadata(child, identity: tree.rootIdentity) : nil
                var action: StorageCleanupAction?
                let reason: String?
                if !StoragePathLabel.isUnambiguous(child.path) {
                    reason = "路径包含控制字符，仅可查看"
                } else if kind == .codexData {
                    reason = "仅缓存和旧日志可按文件清理"
                } else if kind == .simulatorRuntimes {
                    let matches = runtimes.filter { runtimeMatches($0, asset: asset, path: child) }
                    if tree.issues.isEmpty, let node = tree.rootIdentity, node.isDirectory, !node.isSymbolicLink,
                       matches.count == 1, let info = matches.first, notice == nil {
                        let target = runtimeTarget(info, devices: devices)
                        action = .runtime(target)
                        reason = target.unavailableReason
                    } else { reason = "运行时映射不明确或无法完整核实，请在 Xcode 中管理" }
                } else if manifest?.isSafeDirectory != true {
                    reason = "目录未完整核实，或目标为符号链接、包含挂载点，仅可查看"
                } else if kind == .deviceSupport {
                    reason = isSupportVersion(child.lastPathComponent) ? nil : "无法识别为调试支持版本，仅可查看"
                    if reason == nil { action = .directory }
                } else if authoritative == nil {
                    reason = "设备身份或实时状态无法核实，仅可查看"
                } else {
                    reason = authoritative?.cleanupUnavailableReason
                    if let authoritative { action = .simulatorDevice(authoritative.udid) }
                }
                entries.append(DeveloperStorageEntry(
                    kind: kind, path: child.path,
                    name: asset.map { "iOS \($0.SimulatorVersion) (\($0.Build))" } ?? child.lastPathComponent,
                    manifest: manifest, measuredBytes: tree.bytes, modifiedAt: tree.rootIdentity?.modifiedAt, issues: tree.issues,
                    device: kind == .simulators ? device : nil, cleanupUnavailableReason: reason, cleanupAction: action
                ))
            }
        } catch {
            let nsError = error as NSError
            missing = nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)
            if !missing { issues.append(error.localizedDescription) }
        }
        return DeveloperStorageSnapshot(
            kind: kind, path: root.path,
            entries: entries.sorted {
                $0.measuredBytes == $1.measuredBytes ? $0.path < $1.path : $0.measuredBytes > $1.measuredBytes
            }, allocatedBytes: bytes, scannedAt: Date(), issues: issues,
            isMissing: missing, notice: notice
        )
    }

    private func scanTree(_ url: URL, device: Int32) -> TreeScan {
        var rootInodes = Set<String>()
        return scanTree(url, device: device, captureManifest: true, rootInodes: &rootInodes)
    }

    private func scanTree(_ url: URL, device: Int32, captureManifest: Bool, rootInodes: inout Set<String>) -> TreeScan {
        var result = TreeScan()
        var seen = Set<String>()
        func visit(_ target: URL) {
            do {
                let node = try identity(target)
                if target.path == url.path { result.rootIdentity = node }
                if captureManifest { result.nodes.append(node) }
                if node.device != device || node.isMountPoint {
                    result.issues.append("跳过挂载点：\(StoragePathLabel.string(target.path))")
                    return
                }
                let key = inodeKey(node)
                if seen.insert(key).inserted { result.bytes += node.allocatedBytes }
                if rootInodes.insert(key).inserted { result.rootContribution += node.allocatedBytes }
                if node.isDirectory && !node.isSymbolicLink {
                    let children = try FileManager.default.contentsOfDirectory(atPath: target.path)
                        .sorted().map { target.appendingPathComponent($0) }
                    for child in children { visit(child) }
                }
            } catch {
                result.issues.append("\(StoragePathLabel.string(target.path))：\(error.localizedDescription)")
            }
        }
        visit(url)
        return result
    }

    private func inodeKey(_ node: StorageNodeIdentity) -> String { "\(node.device):\(node.inode)" }

    private struct RuntimeAssetProperties: Decodable {
        let SimulatorVersion: String
        let Build: String
    }

    private func runtimeAssetMetadata(_ url: URL, identity root: StorageNodeIdentity?) -> RuntimeAssetProperties? {
        struct AssetInfo: Decodable {
            let MobileAssetProperties: RuntimeAssetProperties
        }
        let infoURL = url.appendingPathComponent("Info.plist")
        guard root?.isDirectory == true, root?.isSymbolicLink == false, url.pathExtension == "asset",
              let info = try? identity(infoURL), !info.isDirectory, !info.isSymbolicLink,
              info.logicalBytes < 1_048_576,
              let data = try? Data(contentsOf: infoURL),
              let properties = try? PropertyListDecoder().decode(AssetInfo.self, from: data).MobileAssetProperties,
              !properties.SimulatorVersion.isEmpty, !properties.Build.isEmpty else { return nil }
        return properties
    }

    private func identity(_ url: URL) throws -> StorageNodeIdentity {
        var attributes = stat()
        guard url.path.withCString({ lstat($0, &attributes) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let type = attributes.st_mode & S_IFMT
        let isLink = type == S_IFLNK
        let isDirectory = type == S_IFDIR
        var allocated = Int64(attributes.st_blocks) * 512
        var isMount = false
        // lstat measures the link itself. Never ask resourceValues to resolve it.
        if !isLink {
            let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isVolumeKey])
            allocated = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? Int(allocated))
            var parent = stat()
            guard url.deletingLastPathComponent().path.withCString({ lstat($0, &parent) }) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            isMount = values.isVolume == true || attributes.st_dev != parent.st_dev
        }
        return StorageNodeIdentity(
            path: url.path, mode: attributes.st_mode, owner: attributes.st_uid,
            device: attributes.st_dev, inode: attributes.st_ino,
            logicalBytes: attributes.st_size, allocatedBytes: allocated,
            modifiedSeconds: Int64(attributes.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(attributes.st_mtimespec.tv_nsec),
            changedSeconds: Int64(attributes.st_ctimespec.tv_sec), changedNanoseconds: Int64(attributes.st_ctimespec.tv_nsec),
            isDirectory: isDirectory, isSymbolicLink: isLink, isMountPoint: isMount
        )
    }

    private func isSupportVersion(_ name: String) -> Bool {
        name.range(of: #"^(?:[A-Za-z]+[0-9]+,[0-9]+ )?[0-9]+(?:\.[0-9]+){1,2}(?: \([A-Za-z0-9]+\))?(?: arm64e?)?$"#,
                   options: .regularExpression) != nil
    }

    private struct DeviceList: Decodable {
        let devices: [String: [Device]]
        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
        }
    }

    private func simulatorDevices(root: URL) throws -> [String: SimulatorStorageDevice] {
        let result = try commands.run(executable: "/usr/bin/xcrun",
                                      arguments: ["simctl", "--set", root.path, "list", "devices", "--json"], timeout: 30)
        guard result.status == 0, result.error.isEmpty else {
            throw DeveloperStorageError.command("simctl 无法读取设备。\(result.errorText)")
        }
        let list = try JSONDecoder().decode(DeviceList.self, from: result.output)
        var devices: [String: SimulatorStorageDevice] = [:]
        for (runtime, group) in list.devices {
            for device in group {
                guard UUID(uuidString: device.udid) != nil, devices[device.udid] == nil else {
                    throw DeveloperStorageError.command("simctl 返回了无效或重复的设备标识。")
                }
                devices[device.udid] = SimulatorStorageDevice(udid: device.udid, name: device.name,
                    runtime: runtime, state: device.state, isAvailable: device.isAvailable)
            }
        }
        return devices
    }

    private func deviceFromPlist(_ url: URL) -> SimulatorStorageDevice? {
        struct Device: Decodable { let name: String; let UDID: String; let runtime: String }
        // This is display-only metadata. A plist never grants deletion authority.
        guard UUID(uuidString: url.lastPathComponent) != nil,
              let node = try? identity(url.appendingPathComponent("device.plist")), !node.isSymbolicLink,
              node.logicalBytes < 1_048_576,
              let data = try? Data(contentsOf: url.appendingPathComponent("device.plist")),
              let device = try? PropertyListDecoder().decode(Device.self, from: data),
              device.UDID == url.lastPathComponent else { return nil }
        return SimulatorStorageDevice(udid: device.UDID, name: device.name, runtime: device.runtime,
                                      state: "", isAvailable: nil)
    }

    private func runtimeInfos() throws -> [StorageRuntimeInfo] {
        let result = try commands.run(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "list", "--json"], timeout: 30)
        guard result.status == 0, result.error.isEmpty else {
            throw DeveloperStorageError.command("无法读取系统运行时列表。\(result.errorText)")
        }
        let values = try JSONDecoder().decode([String: StorageRuntimeInfo].self, from: result.output)
        for (key, value) in values {
            guard key == value.identifier, UUID(uuidString: value.identifier) != nil else {
                throw DeveloperStorageError.command("系统返回了无效的运行时标识。")
            }
        }
        return Array(values.values)
    }

    private func runtimeMatches(_ info: StorageRuntimeInfo, asset: RuntimeAssetProperties?, path: URL) -> Bool {
        guard let asset, info.platformIdentifier == "com.apple.platform.iphonesimulator",
              info.version == asset.SimulatorVersion, info.build == asset.Build,
              info.runtimeIdentifier.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-"),
              StoragePathLabel.isUnambiguous(info.path), StoragePathLabel.isUnambiguous(info.runtimeIdentifier) else { return false }
        let managedPath = URL(fileURLWithPath: info.path).standardizedFileURL
        // Accept only the package itself or its exact AssetData child, never an
        // arbitrary prefix match or another package with the same OS version.
        guard managedPath.resolvingSymlinksInPath().path == managedPath.path else { return false }
        return managedPath.path == path.path || managedPath.path == path.appendingPathComponent("AssetData").path
    }

    private func runtimeTarget(_ info: StorageRuntimeInfo, devices: [String: SimulatorStorageDevice]) -> StorageRuntimeTarget {
        StorageRuntimeTarget(info: info, affectedDevices: devices.values.filter { $0.runtime == info.runtimeIdentifier }
            .sorted { $0.udid < $1.udid })
    }

    private func requireDirectory(_ url: URL) throws -> StorageNodeIdentity {
        let node = try identity(url)
        guard node.isDirectory, !node.isSymbolicLink, !node.isMountPoint,
              url.resolvingSymlinksInPath().path == url.path else { throw DeveloperStorageError.unsafeTarget }
        return node
    }

    private func validateRuntimePath(_ entry: DeveloperStorageEntry) throws -> URL {
        guard entry.kind == .simulatorRuntimes, case let .runtime(target) = entry.cleanupAction,
              target.unavailableReason == nil, UUID(uuidString: target.info.identifier) != nil else {
            throw DeveloperStorageError.unsafeTarget
        }
        let root = rootURL(for: .simulatorRuntimes)
        let url = URL(fileURLWithPath: entry.path).standardizedFileURL
        _ = try requireDirectory(root)
        let node = try requireDirectory(url)
        guard url.path == entry.path, url.deletingLastPathComponent().path == root.path,
              url.pathExtension == "asset", StoragePathLabel.isUnambiguous(url.path),
              runtimeMatches(target.info, asset: runtimeAssetMetadata(url, identity: node), path: url) else {
            throw DeveloperStorageError.unsafeTarget
        }
        return url
    }

    private func revalidateRuntime(_ entry: DeveloperStorageEntry) throws {
        let url = try validateRuntimePath(entry)
        guard case let .runtime(expected) = entry.cleanupAction else { throw DeveloperStorageError.unsafeTarget }
        let infos = try runtimeInfos()
        let matches = infos.filter { runtimeMatches($0, asset: runtimeAssetMetadata(url, identity: try? identity(url)), path: url) }
        guard matches.count == 1, let current = matches.first, current == expected.info else { throw DeveloperStorageError.targetChanged }
        let devices = try simulatorDevices(root: rootURL(for: .simulators))
        let target = runtimeTarget(current, devices: devices)
        guard target == expected, target.unavailableReason == nil else { throw DeveloperStorageError.targetChanged }
    }

    private static let cacheDirectories: Set<String> = ["codex_apps_server_info", "codex_apps_tools", "remote_plugin_catalog"]

    private func codexFileKind(_ url: URL, node: StorageNodeIdentity) -> CodexCleanupFileKind? {
        guard node.mode & S_IFMT == S_IFREG, !node.isSymbolicLink, !node.isMountPoint,
              node.owner == getuid(), StoragePathLabel.isUnambiguous(url.path) else { return nil }
        let root = rootURL(for: .codexData)
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let lower = name.lowercased()
        guard !lower.contains(".sqlite"), !lower.contains(".db"), !lower.hasSuffix("-wal"), !lower.hasSuffix("-shm") else { return nil }
        if parent.deletingLastPathComponent().path == root.appendingPathComponent("cache").path,
           Self.cacheDirectories.contains(parent.lastPathComponent), url.pathExtension == "json" {
            return .cache
        }
        if parent.path == root.appendingPathComponent("log").path,
           name.range(of: #"^[A-Za-z0-9_-][A-Za-z0-9._-]*\.log(?:\.[0-9]+)?(?:\.gz)?$"#, options: .regularExpression) != nil,
           node.modifiedAt < now().addingTimeInterval(-7 * 86_400) { return .oldLog }
        return nil
    }

    private func codexCleanupCandidates(_ parent: DeveloperStorageEntry) throws -> [DeveloperStorageEntry] {
        let root = rootURL(for: .codexData)
        _ = try requireDirectory(root)
        let url = URL(fileURLWithPath: parent.path).standardizedFileURL
        guard parent.canListCleanupCandidates, url.path == root.appendingPathComponent(parent.name).path else {
            throw DeveloperStorageError.unsafeTarget
        }
        _ = try requireDirectory(url)
        var directories: [URL] = []
        if parent.name == "cache" {
            for name in Self.cacheDirectories.sorted() {
                let directory = url.appendingPathComponent(name)
                do { _ = try requireDirectory(directory); directories.append(directory) }
                catch {
                    let error = error as NSError
                    if error.domain != NSPOSIXErrorDomain || error.code != Int(ENOENT) { throw error }
                }
            }
        } else { directories = [url] }
        var entries: [DeveloperStorageEntry] = []
        for directory in directories {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
                let file = directory.appendingPathComponent(name)
                let node = try identity(file)
                guard let kind = codexFileKind(file, node: node) else { continue }
                let manifest = StorageManifest(canonicalPath: file.resolvingSymlinksInPath().path, nodes: [node], allocatedBytes: node.allocatedBytes)
                entries.append(DeveloperStorageEntry(kind: .codexData, path: file.path, name: name,
                    manifest: manifest, measuredBytes: node.allocatedBytes, modifiedAt: node.modifiedAt,
                    issues: [], device: nil, cleanupUnavailableReason: nil, cleanupAction: .codexFile(kind)))
            }
        }
        return entries.sorted { $0.measuredBytes == $1.measuredBytes ? $0.path < $1.path : $0.measuredBytes > $1.measuredBytes }
    }

    private func validateCodexFile(_ entry: DeveloperStorageEntry) throws -> URL {
        guard entry.kind == .codexData, case let .codexFile(expected) = entry.cleanupAction,
              let manifest = entry.manifest, manifest.isSafeFile, entry.canClean else { throw DeveloperStorageError.unsafeTarget }
        let root = rootURL(for: .codexData)
        _ = try requireDirectory(root)
        let url = URL(fileURLWithPath: entry.path).standardizedFileURL
        guard url.path == entry.path, url.resolvingSymlinksInPath().path == url.path,
              manifest.canonicalPath == url.path, let original = manifest.root,
              codexFileKind(url, node: original) == expected else { throw DeveloperStorageError.unsafeTarget }
        let parent = url.deletingLastPathComponent()
        _ = try requireDirectory(parent)
        if expected == .cache { _ = try requireDirectory(root.appendingPathComponent("cache")) }
        let current = try identity(url)
        guard current == original, codexFileKind(url, node: current) == expected else { throw DeveloperStorageError.targetChanged }
        return url
    }

    private func validatePath(_ entry: DeveloperStorageEntry) throws -> URL {
        guard entry.canClean, let action = entry.cleanupAction, action.kind == entry.kind else { throw DeveloperStorageError.unsafeTarget }
        if case .codexFile = action { return try validateCodexFile(entry) }
        if case .runtime = action {
            let target = try validateRuntimePath(entry)
            guard entry.manifest?.isSafeDirectory == true else { throw DeveloperStorageError.unsafeTarget }
            return target
        }
        let root = rootURL(for: entry.kind)
        let target = URL(fileURLWithPath: entry.path).standardizedFileURL
        guard entry.canClean, let manifest = entry.manifest, manifest.isSafeDirectory,
              StoragePathLabel.isUnambiguous(entry.path),
              target.deletingLastPathComponent().path == root.path,
              target.path == entry.path, manifest.canonicalPath == target.path,
              root.resolvingSymlinksInPath().path == root.path,
              target.resolvingSymlinksInPath().path == target.path,
              let rootNode = try? identity(root), rootNode.isDirectory,
              !rootNode.isSymbolicLink, !rootNode.isMountPoint,
              manifest.root?.owner == getuid() else { throw DeveloperStorageError.unsafeTarget }
        if case .directory = action {
            guard isSupportVersion(target.lastPathComponent) else { throw DeveloperStorageError.unsafeTarget }
        } else {
            guard case let .simulatorDevice(udid) = action, let device = entry.device, device.udid == udid, device.udid == target.lastPathComponent,
                  UUID(uuidString: device.udid) != nil, device.cleanupUnavailableReason == nil else {
                throw DeveloperStorageError.unsafeTarget
            }
        }
        return target
    }

    private func revalidate(_ entry: DeveloperStorageEntry, target: URL, checkDeviceState: Bool = true) throws {
        _ = try validatePath(entry)
        if case .runtime = entry.cleanupAction { try revalidateRuntime(entry) }
        if entry.kind == .simulators && checkDeviceState {
            let devices = try simulatorDevices(root: rootURL(for: entry.kind))
            guard let expected = entry.device, devices[expected.udid] == expected,
                  expected.cleanupUnavailableReason == nil else { throw DeveloperStorageError.targetChanged }
        }
        guard let expected = entry.manifest, let device = expected.root?.device,
              scanTree(target, device: device).manifest == expected else { throw DeveloperStorageError.targetChanged }
    }

    private func availableSpace(_ root: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: root.path),
              let value = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return value.int64Value
    }

    private func cleanSynchronously(_ entry: DeveloperStorageEntry) throws -> StorageCleanupResult {
        let target = try validatePath(entry)
        let root = rootURL(for: entry.kind)
        let before = scanSynchronously(entry.kind)
        let availableBefore = availableSpace(root)
        try removeTarget(entry, target: target)
        let after = scanSynchronously(entry.kind)
        let availableAfter = availableSpace(root)
        let reduction: Int64?
        if before.isComplete, after.isComplete, let old = before.allocatedBytes, let new = after.allocatedBytes {
            reduction = old - new
        } else { reduction = nil }
        let availableChange: Int64?
        if let old = availableBefore, let new = availableAfter { availableChange = new - old }
        else { availableChange = nil }
        return try StorageCleanupResult(snapshot: after, targetRemoved: cleanupTargetRemoved(entry), directoryReduction: reduction, volumeAvailableChange: availableChange)
    }

    private func removeTarget(_ entry: DeveloperStorageEntry, target: URL) throws {
        let root = rootURL(for: entry.kind)
        try revalidate(entry, target: target, checkDeviceState: false)
        if case let .runtime(runtime) = entry.cleanupAction {
            // Runtime backing images can be mounted by system services while no
            // simulator uses them. Let simctl manage unmounting; never raw-delete.
            try revalidate(entry, target: target)
            let result = try commands.run(executable: "/usr/bin/xcrun",
                arguments: ["simctl", "runtime", "delete", runtime.info.identifier], timeout: 120)
            guard result.status == 0, result.error.isEmpty else {
                throw DeveloperStorageError.command("运行时卸载失败，请在 Xcode 中管理。\(result.errorText)")
            }
            return
        }
        let arguments: [String]
        if case .codexFile = entry.cleanupAction { arguments = ["-nP", "--", target.path] }
        else { arguments = ["-nP", "+D", target.path] }
        let occupancy = try commands.run(executable: "/usr/sbin/lsof", arguments: arguments, timeout: 30)
        guard occupancy.output.isEmpty else { throw DeveloperStorageError.occupied }
        // lsof returns 1 with empty stdout/stderr when it found no matching files.
        // Warnings (including incomplete traversal) are never treated as empty.
        guard occupancy.status == 1, occupancy.error.isEmpty else {
            throw DeveloperStorageError.command("无法完整确认目录未被占用，已停止清理。\(occupancy.errorText)")
        }
        try revalidate(entry, target: target)
        if case .directory = entry.cleanupAction {
            try FileManager.default.removeItem(at: target)
        } else if case .codexFile = entry.cleanupAction {
            try FileManager.default.removeItem(at: target)
        } else if case .simulatorDevice = entry.cleanupAction, let device = entry.device {
            let result = try commands.run(executable: "/usr/bin/xcrun",
                arguments: ["simctl", "--set", root.path, "delete", device.udid], timeout: 120)
            guard result.status == 0, result.error.isEmpty else {
                throw DeveloperStorageError.command("删除设备失败或结果不完整，请刷新核实。\(result.errorText)")
            }
        }
    }

    private func targetRemoved(_ target: URL) -> Bool {
        var targetStat = stat()
        let targetStatus = target.path.withCString { lstat($0, &targetStat) }
        return targetStatus != 0 && errno == ENOENT
    }

    private func cleanupTargetRemoved(_ entry: DeveloperStorageEntry) throws -> Bool {
        guard targetRemoved(URL(fileURLWithPath: entry.path)) else { return false }
        if case let .runtime(target) = entry.cleanupAction {
            return try !runtimeInfos().contains { $0.identifier == target.info.identifier }
        }
        return true
    }

    private func cleanBatchOnWorker(_ entries: [DeveloperStorageEntry], progress: @escaping @Sendable (StorageCleanupProgress) async -> Void) async -> StorageBatchCleanupResult {
        if entries.count != 1, entries.contains(where: { if case .runtime = $0.cleanupAction { return true }; return false }) {
            return StorageBatchCleanupResult(snapshots: [], items: entries.map {
                StorageBatchItemResult(path: $0.path, removed: false, message: "运行时必须逐个确认卸载，不能混入批量清理。")
            }, measurements: [])
        }
        let kinds = DeveloperStorageKind.allCases.filter { kind in entries.contains { $0.kind == kind && $0.canClean } }
        var beforeBytes: [DeveloperStorageKind: Int64] = [:]
        var volumes: [Int32: (root: URL, available: Int64)] = [:]
        for kind in kinds {
            // Keep only totals, releasing this scan's large identity arrays before
            // processing targets. Frozen confirmation manifests remain authoritative.
            let before = scanSynchronously(kind)
            if before.isComplete { beforeBytes[kind] = before.allocatedBytes }
            let root = rootURL(for: kind)
            if let node = try? identity(root), volumes[node.device] == nil, let free = availableSpace(root) {
                volumes[node.device] = (root, free)
            }
        }
        var items: [StorageBatchItemResult] = []
        var seen = Set<String>()
        for (index, entry) in entries.enumerated() {
            await progress(StorageCleanupProgress(entry: entry, index: index + 1, total: entries.count))
            do {
                guard seen.insert(entry.id).inserted else { throw DeveloperStorageError.unsafeTarget }
                let target = try validatePath(entry)
                try removeTarget(entry, target: target)
                let removed = try cleanupTargetRemoved(entry)
                items.append(StorageBatchItemResult(path: entry.path, removed: removed,
                    message: removed ? "已核实目标已移除。" : "目标或系统资源仍存在，请检查详情或在 Xcode 中管理；不会自动重试。"))
            } catch {
                // A failed atomic target never widens or retries. Other explicitly
                // confirmed targets remain independent and can still be processed.
                items.append(StorageBatchItemResult(path: entry.path, removed: false,
                    message: "清理未完成：\(error.localizedDescription)\n如需重试，请重新选择并确认条目。"))
            }
        }
        let snapshots = kinds.map { scanSynchronously($0) }
        var measurements: [String] = snapshots.map { after in
            if after.isComplete, let old = beforeBytes[after.kind], let new = after.allocatedBytes {
                return "\(after.kind.title)占用变化（减少为正）：\(StorageSizeFormatter.string(old - new))。"
            }
            return "\(after.kind.title)占用变化无法完整测量。"
        }
        for (_, volume) in volumes.sorted(by: { $0.key < $1.key }) {
            if let free = availableSpace(volume.root) {
                let delta = free - volume.available
                measurements.append("所在卷可用空间变化：\(delta >= 0 ? "+" : "")\(StorageSizeFormatter.string(delta))。")
            } else { measurements.append("所在卷可用空间变化无法测量。") }
        }
        if volumes.isEmpty { measurements.append("卷可用空间变化无法测量。") }
        measurements.append("卷空间可能同时受其他进程及 APFS 影响。")
        return StorageBatchCleanupResult(snapshots: snapshots, items: items, measurements: measurements)
    }
}
