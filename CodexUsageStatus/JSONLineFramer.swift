import Foundation

struct JSONLineFramer: Sendable {
    private(set) var buffer = Data()
    private let maximumBufferSize: Int

    init(maximumBufferSize: Int = 1_048_576) {
        self.maximumBufferSize = maximumBufferSize
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= maximumBufferSize else {
            buffer.removeAll(keepingCapacity: false)
            throw CodexAppServerError.invalidResponse
        }

        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            if !line.isEmpty {
                lines.append(Data(line))
            }
        }
        return lines
    }
}
