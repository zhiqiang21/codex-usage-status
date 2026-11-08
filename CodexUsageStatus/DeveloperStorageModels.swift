import Darwin
import Foundation

// Foundation path standardization may rewrite /private/tmp to /tmp even
// though /tmp is a symlink. Safety checks need the physical, POSIX path.
enum StorageCanonicalPath {
    static func resolve(_ url: URL) -> String? {
        url.path.withCString { path in
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}

enum StorageFileAccess {
    static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
        if error.domain == NSCocoaErrorDomain,
           [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileWriteNoPermission.rawValue].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlying)
        }
        return false
    }
}

enum DeveloperStorageKind: String, CaseIterable, Identifiable, Sendable {
    case deviceSupport
    case simulators
    case simulatorRuntimes
    case codexData
    case userCaches
    case appSupport
    case systemTmp

    var id: String { rawValue }
    var title: String {
        switch self {
        case .deviceSupport: "真机调试支持"
        case .simulators: "模拟器设备"
        case .simulatorRuntimes: "iOS 模拟器运行时"
        case .codexData: "Codex 数据"
        case .userCaches: "用户缓存"
        case .appSupport: "应用支持数据"
        case .systemTmp: "系统临时目录"
        }
    }
    var relativePath: String {
        switch self {
        case .deviceSupport: "Library/Developer/Xcode/iOS DeviceSupport"
        case .simulators: "Library/Developer/CoreSimulator/Devices"
        case .simulatorRuntimes: "System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime"
        case .codexData: ".codex"
        case .userCaches: "Library/Caches"
        case .appSupport: "Library/Application Support"
        case .systemTmp: "private/tmp"
        }
    }

    var showsBatchSelection: Bool {
        switch self {
        case .deviceSupport, .simulators, .userCaches, .systemTmp: true
        default: false
        }
    }
    var displayPath: String {
        switch self {
        case .simulatorRuntimes: "/" + relativePath
        case .systemTmp: "/" + relativePath
        default: "~/" + relativePath
        }
    }
    // Library categories use conservative eligibility checks; these cannot
    // prove that application data is no longer needed.
    var isLibraryManagement: Bool {
        switch self {
        case .userCaches, .appSupport, .systemTmp: true
        default: false
        }
    }
    var monitoringDescription: String? {
        switch self {
        case .simulatorRuntimes: "通过系统接口逐个卸载；使用中的运行时不能卸载。"
        case .codexData: "仅开放白名单缓存和超过 7 天的日志清理；会话和图片保持只读。"
        case .userCaches: "仅开放归属已确认且未运行的应用缓存；未知归属保持只读。"
        case .appSupport: "应用支持数据可能包含设置和用户记录，全部保持只读。"
        case .systemTmp: "仅开放整棵树均属当前用户且超过 3 天未修改的普通文件和目录；修改时间不代表未使用。"
        default: nil
        }
    }

    func root(in home: URL) -> URL {
        switch self {
        case .simulatorRuntimes, .systemTmp: URL(fileURLWithPath: "/" + relativePath)
        default: home.appendingPathComponent(relativePath)
        }
    }
}

struct StorageNodeIdentity: Equatable, Sendable {
    let path: String
    let mode: UInt16
    let owner: UInt32
    let device: Int32
    let inode: UInt64
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let isMountPoint: Bool

    var modifiedAt: Date {
        Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1e9)
    }
}

// Immutable scan evidence. Descendant identities also catch changes that do not
// modify the top-level directory's mtime (for example editing an existing file).
struct StorageManifest: Equatable, Sendable {
    let canonicalPath: String
    let nodes: [StorageNodeIdentity]
    let allocatedBytes: Int64

    var root: StorageNodeIdentity? { nodes.first }
    // Evidence is immutable; calculate these once rather than walking every
    // descendant on the MainActor for each row, selection, and confirmation.
    let isSafeDirectory: Bool
    let isSafeFile: Bool

    init(canonicalPath: String, nodes: [StorageNodeIdentity], allocatedBytes: Int64) {
        self.canonicalPath = canonicalPath
        self.nodes = nodes
        self.allocatedBytes = allocatedBytes
        let root = nodes.first
        isSafeDirectory = root?.isDirectory == true && root?.isSymbolicLink == false
            && !nodes.contains { $0.isMountPoint }
        isSafeFile = nodes.count == 1 && root.map {
            $0.mode & 0o170000 == 0o100000 && !$0.isSymbolicLink && !$0.isMountPoint
        } == true
    }
}

struct StorageRuntimeInfo: Decodable, Equatable, Sendable {
    let identifier: String
    let path: String
    let parentMountPath: String?
    let mountPath: String?
    let platformIdentifier: String
    let runtimeIdentifier: String
    let version: String
    let build: String
    let state: String
    let deletable: Bool
}

struct StorageRuntimeTarget: Equatable, Sendable {
    let info: StorageRuntimeInfo
    let affectedDevices: [SimulatorStorageDevice]

    var unavailableReason: String? {
        guard info.deletable else { return "系统未允许删除，请在 Xcode 中管理" }
        guard info.state == "Ready" else { return "运行时尚未就绪，请刷新或在 Xcode 中管理" }
        guard affectedDevices.allSatisfy({ $0.cleanupUnavailableReason == nil }) else {
            return "关联设备正在使用或状态未核实，请关闭设备后刷新"
        }
        return nil
    }
}

enum CodexCleanupFileKind: Equatable, Sendable {
    case cache
    case oldLog
}

enum StorageCleanupAction: Equatable, Sendable {
    case directory
    case simulatorDevice(String)
    case runtime(StorageRuntimeTarget)
    case codexFile(CodexCleanupFileKind)
    case libraryDirectory(DeveloperStorageKind)

    var kind: DeveloperStorageKind {
        switch self {
        case .directory: .deviceSupport
        case .simulatorDevice: .simulators
        case .runtime: .simulatorRuntimes
        case .codexFile: .codexData
        case let .libraryDirectory(kind): kind
        }
    }
    var allowsBatch: Bool {
        switch self {
        case .runtime: return false
        case let .libraryDirectory(kind): return kind == .userCaches || kind == .systemTmp
        default: return true
        }
    }
    var title: String {
        switch self {
        case .directory, .codexFile, .libraryDirectory: "永久删除"
        case .simulatorDevice: "删除设备"
        case .runtime: "卸载运行时"
        }
    }
}

struct SimulatorStorageDevice: Equatable, Sendable {
    let udid: String
    let name: String
    let runtime: String
    let state: String
    let isAvailable: Bool?

    var cleanupUnavailableReason: String? {
        switch state {
        case "Shutdown": nil
        // Old devices with a missing runtime can remain in Creating indefinitely.
        // Only an explicit simctl availability=false allows this exception.
        case "Creating" where isAvailable == false: nil
        case "Creating": "设备正在创建，请完成后刷新"
        case "Booting", "Booted", "Shutting Down", "ShuttingDown": "请先在模拟器中关闭设备，再刷新"
        default: "无法确认设备状态，暂不能删除"
        }
    }

    var availabilityTitle: String {
        switch isAvailable {
        case true: ""
        case false: " · 不可用"
        case nil: " · 可用性未知"
        }
    }

    var runtimeTitle: String {
        let value = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        guard let separator = value.firstIndex(of: "-") else { return value }
        return String(value[..<separator]) + " "
            + value[value.index(after: separator)...].replacingOccurrences(of: "-", with: ".")
    }

    var stateTitle: String {
        switch state {
        case "Shutdown": "已关闭"
        case "Booted": "运行中"
        case "Booting": "正在启动"
        case "Shutting Down", "ShuttingDown": "正在关闭"
        case "Creating": isAvailable == false ? "创建未完成" : "正在创建"
        default: state.isEmpty ? "状态未知" : state
        }
    }
}

struct DeveloperStorageEntry: Identifiable, Equatable, Sendable {
    let kind: DeveloperStorageKind
    let path: String
    let name: String
    let manifest: StorageManifest?
    let measuredBytes: Int64
    let modifiedAt: Date?
    let issues: [String]
    let device: SimulatorStorageDevice?
    let cleanupUnavailableReason: String?
    var cleanupAction: StorageCleanupAction? = nil

    var id: String { path }
    var displayName: String {
        if let device { return device.name }
        if kind == .codexData {
            switch name {
            case "archived_sessions": return "归档会话"
            case "generated_images": return "生成图片"
            case "sessions": return "会话记录"
            case "attachments": return "附件"
            case "plugins": return "插件"
            case "worktrees": return "工作树"
            case "log": return "日志"
            default: break
            }
        }
        return name
    }
    var canClean: Bool {
        guard let cleanupAction, cleanupAction.kind == kind, cleanupUnavailableReason == nil else { return false }
        switch cleanupAction {
        case .directory, .simulatorDevice: return manifest?.isSafeDirectory == true
        case .codexFile: return manifest?.isSafeFile == true
        case let .runtime(target): return target.unavailableReason == nil
        case let .libraryDirectory(kind):
            guard let manifest else { return false }
            switch kind {
            case .userCaches: return manifest.isSafeDirectory
            case .systemTmp: return manifest.isSafeDirectory || manifest.isSafeFile
            default: return false
            }
        }
    }
    var cleanupTitle: String { cleanupAction?.title ?? "永久删除" }
    var allowsSelection: Bool { cleanupAction?.allowsBatch == true }
    var canListCleanupCandidates: Bool { kind == .codexData && ["cache", "log"].contains(name) && cleanupAction == nil }
    // Scan-time verdict for the library directories: an eligibility label or
    // the reason an entry cannot be cleaned. Other kinds have authoritative tools.
    var safetyMark: String? {
        guard kind.isLibraryManagement else { return nil }
        return canClean ? "符合清理条件" : cleanupUnavailableReason
    }
    func withManifest(_ manifest: StorageManifest?) -> Self {
        Self(kind: kind, path: path, name: name, manifest: manifest, measuredBytes: measuredBytes, modifiedAt: modifiedAt,
             issues: issues, device: device, cleanupUnavailableReason: cleanupUnavailableReason, cleanupAction: cleanupAction)
    }
    var sizeText: String { (issues.isEmpty ? "" : "至少 ") + StorageSizeFormatter.string(measuredBytes) }
    var confirmationMessage: String {
        let impact: String
        switch cleanupAction {
        case .directory:
            impact = "将永久删除该版本的真机调试支持文件。后续调试对应系统的真机时，可能需要重新生成或下载支持文件。"
        case .simulatorDevice:
            impact = "将永久删除此模拟器设备、已安装应用和本地数据，需要时须重新创建设备。不会删除系统 Runtime。"
        case let .runtime(target):
            let devices = target.affectedDevices.map { "\(StoragePathLabel.string($0.name)) · \($0.udid) · \($0.stateTitle)" }
            impact = "运行时标识：\(target.info.identifier)\n版本：\(target.info.version) (\(target.info.build))\n受影响设备：\n"
                + (devices.isEmpty ? "无" : devices.joined(separator: "\n"))
                + "\n卸载后，关联设备需重新安装此 Runtime 才能使用。不会删除这些设备的数据。"
        case .codexFile(.cache): impact = "将永久删除此缓存文件，之后可能重新生成。不会删除会话、图片或配置。"
        case .codexFile(.oldLog): impact = "将永久删除此旧日志，之后无法用它排查历史问题。"
        case let .libraryDirectory(targetKind):
            switch targetKind {
            case .userCaches: impact = "将永久删除此缓存目录。应用可能重新生成缓存；请先退出相关应用。检查结果不保证应用稍后不会重新使用它。"
            case .appSupport: impact = "应用支持数据保持只读。"
            case .systemTmp: impact = "将永久删除此目标及其内容，无法恢复。所有条目均超过 3 天未修改，但这不代表未使用；进程稍后仍可能读取它。"
            default: impact = "将永久删除此目录或文件，之后无法恢复。"
            }
        case nil: impact = "此条目不支持清理。"
        }
        let identity = device.map { "\($0.name)\n\($0.runtimeTitle) · \($0.stateTitle)\($0.availabilityTitle)\nUDID：\($0.udid)\n" } ?? "\(name)\n"
        let modified = modifiedAt.map { "\n修改于：\($0.formatted())" } ?? ""
        return "\(identity)\(StoragePathLabel.string(path))\n占用：\(sizeText)\(modified)\n\n\(impact)"
    }
}

struct DeveloperStorageSnapshot: Sendable {
    let kind: DeveloperStorageKind
    let path: String
    let entries: [DeveloperStorageEntry]
    let allocatedBytes: Int64?
    let scannedAt: Date
    let issues: [String]
    let isMissing: Bool
    let notice: String?
    let permissionDeniedPaths: [String]

    init(kind: DeveloperStorageKind, path: String, entries: [DeveloperStorageEntry], allocatedBytes: Int64?,
         scannedAt: Date, issues: [String], isMissing: Bool, notice: String?, permissionDeniedPaths: [String] = []) {
        self.kind = kind
        self.path = path
        self.entries = entries
        self.allocatedBytes = allocatedBytes
        self.scannedAt = scannedAt
        self.issues = issues
        self.isMissing = isMissing
        self.notice = notice
        self.permissionDeniedPaths = permissionDeniedPaths
    }

    var isComplete: Bool { !isMissing && allocatedBytes != nil && issues.isEmpty }
    var sizeText: String {
        guard let allocatedBytes else { return isMissing ? "目录不存在" : "无法读取" }
        return (issues.isEmpty ? "" : "至少 ") + StorageSizeFormatter.string(allocatedBytes)
    }
}

struct StorageCleanupRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let entries: [DeveloperStorageEntry]

    var title: String {
        entries.count == 1 ? "确认\(entries[0].cleanupTitle)？" : "确认删除 \(entries.count) 个项目？"
    }

    var actionTitle: String {
        entries.count == 1 ? entries[0].cleanupTitle : "永久删除 \(entries.count) 项"
    }
}

struct StorageCleanupProgress: Sendable {
    let entry: DeveloperStorageEntry
    let index: Int
    let total: Int
}

struct StorageBatchItemResult: Sendable {
    let path: String
    let removed: Bool
    let message: String
}

struct StorageBatchCleanupResult: Sendable {
    let snapshots: [DeveloperStorageSnapshot]
    let items: [StorageBatchItemResult]
    // Each affected root/volume is measured once before and once after the batch.
    let measurements: [String]

    var hasFailures: Bool { items.contains { !$0.removed } }
    var message: String {
        let removed = items.filter(\.removed).count
        let details = items.map { "\(StoragePathLabel.string($0.path))\n\($0.message)" }
        return (["已清理 \(removed)/\(items.count) 个项目。"] + measurements + details).joined(separator: "\n\n")
    }
}

enum StorageSizeFormatter {
    static func string(_ bytes: Int64) -> String {
        let magnitude = abs(Double(bytes))
        if magnitude >= 1_073_741_824 { return String(format: "%.2f GiB", Double(bytes) / 1_073_741_824) }
        return String(format: "%.2f MiB", Double(bytes) / 1_048_576)
    }
}

enum StoragePathLabel {
    static func isUnambiguous(_ path: String) -> Bool {
        !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func string(_ path: String) -> String {
        isUnambiguous(path) ? path : String(reflecting: path)
    }
}

enum DeveloperStorageError: LocalizedError {
    case unsafeTarget
    case targetChanged
    case occupied
    case command(String)

    var errorDescription: String? {
        switch self {
        case .unsafeTarget: "无法确认目标安全性，已停止清理。请刷新后查看。"
        case .targetChanged: "目标内容或设备状态已变化，已停止清理。请刷新后重新确认。"
        case .occupied: "目录仍被进程占用，已停止清理。请关闭相关应用后刷新并重试。"
        case let .command(message): message
        }
    }
}

struct StorageCleanupResult: Sendable {
    let snapshot: DeveloperStorageSnapshot
    let targetRemoved: Bool
    let directoryReduction: Int64?
    let volumeAvailableChange: Int64?

    var message: String {
        var parts = [targetRemoved ? "已核实目标已移除。" : "目标仍存在，请检查详情；不会自动重试。"]
        if let directoryReduction {
            parts.append("目录占用变化（减少为正）：\(StorageSizeFormatter.string(directoryReduction))。")
        } else {
            parts.append("目录占用变化无法完整测量。")
        }
        if let volumeAvailableChange {
            parts.append("卷可用空间变化：\(volumeAvailableChange >= 0 ? "+" : "")\(StorageSizeFormatter.string(volumeAvailableChange))。")
        } else {
            parts.append("卷可用空间变化无法测量。")
        }
        parts.append("卷空间可能同时受其他进程及 APFS 影响。")
        return parts.joined(separator: "\n")
    }
}
