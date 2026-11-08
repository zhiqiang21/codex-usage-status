import Darwin
import Foundation

struct StorageCommandResult: Sendable {
    let status: Int32
    let output: Data
    let error: Data

    var errorText: String { String(decoding: error.prefix(2_000), as: UTF8.self) }
}

protocol StorageCommandRunning: Sendable {
    // Blocking work: callers must run this on a background executor.
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> StorageCommandResult
}

private final class StorageCommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var failed = false
    private var overflow = false

    func drain(_ handle: FileHandle) {
        do {
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                lock.lock()
                if data.count + chunk.count <= 8 * 1_024 * 1_024 {
                    data.append(chunk)
                } else {
                    // Continue draining even after overflow to avoid blocking the child.
                    overflow = true
                }
                lock.unlock()
            }
        } catch {
            lock.lock()
            failed = true
            lock.unlock()
        }
    }

    func value() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !failed && !overflow else {
            throw DeveloperStorageError.command("工具输出不完整，已停止操作。")
        }
        return data
    }
}

struct StorageCommandRunner: StorageCommandRunning {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> StorageCommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let output = StorageCommandCapture()
        let error = StorageCommandCapture()
        let exited = DispatchSemaphore(value: 0)
        let drained = DispatchGroup()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in exited.signal() }

        try process.run()
        // Close the parent's write ends, otherwise readers can never receive EOF.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        for (capture, handle) in [
            (output, outputPipe.fileHandleForReading),
            (error, errorPipe.fileHandleForReading),
        ] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                capture.drain(handle)
                drained.leave()
            }
        }

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 2) == .timedOut {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        let fullyDrained = drained.wait(timeout: .now() + 2) == .success
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
        guard !timedOut else {
            throw DeveloperStorageError.command("工具执行超时，操作结果需重新核实；不会自动重试。")
        }
        guard fullyDrained, !process.isRunning else {
            throw DeveloperStorageError.command("无法完整读取工具结果，已停止操作。")
        }
        return try StorageCommandResult(status: process.terminationStatus, output: output.value(), error: error.value())
    }
}
