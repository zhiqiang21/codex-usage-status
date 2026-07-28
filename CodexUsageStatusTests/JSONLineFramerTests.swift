import XCTest
@testable import CodexUsageStatus

final class JSONLineFramerTests: XCTestCase {
    func testFramesFragmentedAndMultipleLines() throws {
        var framer = JSONLineFramer()

        XCTAssertTrue(
            try framer.append(Data(#"{"id":1,"res"#.utf8)).isEmpty
        )

        let lines = try framer.append(
            Data(
                """
                ult":{}}
                {"method":"updated"}
                """.utf8
            ) + Data([0x0A])
        )

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(
            String(decoding: lines[0], as: UTF8.self),
            #"{"id":1,"result":{}}"#
        )
        XCTAssertEqual(
            String(decoding: lines[1], as: UTF8.self),
            #"{"method":"updated"}"#
        )
    }

    func testRejectsOversizedUnterminatedPayloadAndClearsBuffer() {
        var framer = JSONLineFramer(maximumBufferSize: 8)

        XCTAssertThrowsError(
            try framer.append(Data(repeating: 0x61, count: 9))
        )
        XCTAssertTrue(framer.buffer.isEmpty)
    }
}
