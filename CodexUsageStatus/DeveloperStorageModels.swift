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
        case .deviceSupport: L10n.tr("Device Support")
        case .simulators: L10n.tr("Simulator Devices")
        case .simulatorRuntimes: L10n.tr("iOS Simulator Runtimes")
        case .codexData: L10n.tr("Codex Data")
        case .userCaches: L10n.tr("User Caches")
        case .appSupport: L10n.tr("Application Support")
        case .systemTmp: L10n.tr("System Temporary Files")
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
        case .simulatorRuntimes: L10n.tr("Uninstall runtimes individually through system tools. Runtimes in use cannot be uninstalled.")
        case .codexData: L10n.tr("Only allowlisted caches and logs older than 7 days can be cleaned. Sessions and images are read-only.")
        case .userCaches: L10n.tr("Only caches belonging to identified, inactive apps can be cleaned. Caches with unknown owners are read-only.")
        case .appSupport: L10n.tr("Application support may contain settings and user records. All entries are read-only.")
        case .systemTmp: L10n.tr("Only regular files and directories whose entire tree belongs to the current user and has not changed for over 3 days can be cleaned. Modification times do not prove they are unused.")
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
        guard info.deletable else { return L10n.tr("The system does not allow deletion. Manage this runtime in Xcode") }
        guard info.state == "Ready" else { return L10n.tr("The runtime is not ready. Refresh or manage it in Xcode") }
        guard affectedDevices.allSatisfy({ $0.cleanupUnavailableReason == nil }) else {
            return L10n.tr("Associated devices are in use or unverified. Shut them down and refresh")
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
        case .directory, .codexFile, .libraryDirectory: L10n.tr("Delete Permanently")
        case .simulatorDevice: L10n.tr("Delete Device")
        case .runtime: L10n.tr("Uninstall Runtime")
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
        case "Creating": L10n.tr("The device is being created. Refresh when creation completes")
        case "Booting", "Booted", "Shutting Down", "ShuttingDown": L10n.tr("Shut down the device in Simulator, then refresh")
        default: L10n.tr("The device state could not be verified. Deletion is unavailable")
        }
    }

    var availabilityTitle: String {
        switch isAvailable {
        case true: ""
        case false: L10n.tr(" · Unavailable")
        case nil: L10n.tr(" · Availability unknown")
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
        case "Shutdown": L10n.tr("Shut down")
        case "Booted": L10n.tr("Running")
        case "Booting": L10n.tr("Starting")
        case "Shutting Down", "ShuttingDown": L10n.tr("Shutting down")
        case "Creating": isAvailable == false ? L10n.tr("Creation incomplete") : L10n.tr("Creating")
        default: state.isEmpty ? L10n.tr("Unknown state") : state
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
            case "archived_sessions": return L10n.tr("Archived Sessions")
            case "generated_images": return L10n.tr("Generated Images")
            case "sessions": return L10n.tr("Sessions")
            case "attachments": return L10n.tr("Attachments")
            case "plugins": return L10n.tr("Plugins")
            case "worktrees": return L10n.tr("Worktrees")
            case "log": return L10n.tr("Logs")
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
    var cleanupTitle: String { cleanupAction?.title ?? L10n.tr("Delete Permanently") }
    var allowsSelection: Bool { cleanupAction?.allowsBatch == true }
    var canListCleanupCandidates: Bool { kind == .codexData && ["cache", "log"].contains(name) && cleanupAction == nil }
    // Scan-time verdict for the library directories: an eligibility label or
    // the reason an entry cannot be cleaned. Other kinds have authoritative tools.
    var safetyMark: String? {
        guard kind.isLibraryManagement else { return nil }
        return canClean ? L10n.tr("Eligible for cleanup") : cleanupUnavailableReason
    }
    func withManifest(_ manifest: StorageManifest?) -> Self {
        Self(kind: kind, path: path, name: name, manifest: manifest, measuredBytes: measuredBytes, modifiedAt: modifiedAt,
             issues: issues, device: device, cleanupUnavailableReason: cleanupUnavailableReason, cleanupAction: cleanupAction)
    }
    var sizeText: String { (issues.isEmpty ? "" : L10n.tr("At least ")) + StorageSizeFormatter.string(measuredBytes) }
    var confirmationMessage: String {
        let impact: String
        switch cleanupAction {
        case .directory:
            impact = L10n.tr("This permanently deletes device support files for this version. Debugging a device running this system version may require regenerating or downloading these files.")
        case .simulatorDevice:
            impact = L10n.tr("This permanently deletes the simulator device, installed apps, and local data. You will need to recreate the device if needed. The system runtime is preserved.")
        case let .runtime(target):
            let devices = target.affectedDevices.map { "\(StoragePathLabel.string($0.name)) · \($0.udid) · \($0.stateTitle)" }
            impact = L10n.tr("Runtime ID: %@\nVersion: %@ (%@)\nAffected devices:\n", "\(target.info.identifier)", "\(target.info.version)", "\(target.info.build)")
                + (devices.isEmpty ? L10n.tr("None") : devices.joined(separator: "\n"))
                + L10n.tr("\nAfter uninstalling, associated devices will require this runtime to be reinstalled. Their data will be preserved.")
        case .codexFile(.cache): impact = L10n.tr("This permanently deletes this cache file. It may be regenerated later. Sessions, images, and configuration are preserved.")
        case .codexFile(.oldLog): impact = L10n.tr("This permanently deletes this old log. It will no longer be available for troubleshooting past issues.")
        case let .libraryDirectory(targetKind):
            switch targetKind {
            case .userCaches: impact = L10n.tr("This permanently deletes this cache directory. The app may regenerate it. Quit the related app first. These checks cannot guarantee the app will not use it again later.")
            case .appSupport: impact = L10n.tr("Application support data is read-only.")
            case .systemTmp: impact = L10n.tr("This permanently deletes this item and its contents. No entries have changed in over 3 days, but this does not prove they are unused. Processes may still read them later.")
            default: impact = L10n.tr("This permanently deletes this directory or file. It cannot be recovered.")
            }
        case nil: impact = L10n.tr("This item does not support cleanup.")
        }
        let identity = device.map { "\($0.name)\n\($0.runtimeTitle) · \($0.stateTitle)\($0.availabilityTitle)\nUDID: \($0.udid)\n" } ?? "\(name)\n"
        let modified = modifiedAt.map { L10n.tr("\nModified: %@", "\($0.formatted())") } ?? ""
        return L10n.tr("%@%@\nSize: %@%@\n\n%@", "\(identity)", "\(StoragePathLabel.string(path))", "\(sizeText)", "\(modified)", "\(impact)")
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
        guard let allocatedBytes else { return isMissing ? L10n.tr("Directory not found") : L10n.tr("Unable to read") }
        return (issues.isEmpty ? "" : L10n.tr("At least ")) + StorageSizeFormatter.string(allocatedBytes)
    }
}

struct StorageCleanupRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let entries: [DeveloperStorageEntry]

    var title: String {
        entries.count == 1 ? L10n.tr("Confirm %@?", "\(entries[0].cleanupTitle)") : L10n.tr("Delete %@ items?", "\(entries.count)")
    }

    var actionTitle: String {
        entries.count == 1 ? entries[0].cleanupTitle : L10n.tr("Permanently Delete %@ Items", "\(entries.count)")
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
        return ([L10n.tr("Cleaned %@/%@ items.", "\(removed)", "\(items.count)")] + measurements + details).joined(separator: "\n\n")
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
        case .unsafeTarget: L10n.tr("Target safety could not be verified. Cleanup stopped. Refresh to review.")
        case .targetChanged: L10n.tr("The target contents or device state changed. Cleanup stopped. Refresh and confirm again.")
        case .occupied: L10n.tr("The directory is still in use. Cleanup stopped. Close related apps, refresh, and try again.")
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
        var parts = [targetRemoved ? L10n.tr("Verified that the target was removed.") : L10n.tr("The target still exists. Check the details. No automatic retry will occur.")]
        if let directoryReduction {
            parts.append(L10n.tr("Directory usage change (positive means reduction): %@.", "\(StorageSizeFormatter.string(directoryReduction))"))
        } else {
            parts.append(L10n.tr("Directory usage change could not be fully measured."))
        }
        if let volumeAvailableChange {
            parts.append(L10n.tr("Volume free-space change: %@%@.", "\(volumeAvailableChange >= 0 ? "+" : "")", "\(StorageSizeFormatter.string(volumeAvailableChange))"))
        } else {
            parts.append(L10n.tr("Volume free-space change could not be measured."))
        }
        parts.append(L10n.tr("Other processes and APFS may also affect volume space."))
        return parts.joined(separator: "\n")
    }
}
