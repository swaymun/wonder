import XCTest
@testable import WonderPairing

final class ReadTimestampTests: XCTestCase {
    func testMessageTimestampFormatsPreserveOrdering() {
        let values = ["1789153200000", "2026-09-11T19:00:00Z", "2026-09-11T15:00:00-04:00", "2026-09-11T19:00:00.123456Z"]
        let rows = values.enumerated().map { index, value in
            ReadRow(id: String(index), author: "Bot", text: "Message", isUser: false, timestamp: value)
        }
        XCTAssertEqual(rows[0].time, rows[1].time, accuracy: 0.000001)
        XCTAssertEqual(rows[1].time, rows[2].time, accuracy: 0.000001)
        XCTAssertEqual(rows[3].time - rows[1].time, 0.123456, accuracy: 0.000001)
        XCTAssertEqual(ReadRow(id: "bad", author: "Bot", text: "", isUser: false, timestamp: "unavailable").time, 0)
    }

    func testTimestampParsingBenchmark() {
        let timestamp = "2026-09-11T19:00:00.123456Z"
        let count = 2_000
        let oldStart = Date()
        var oldSum = 0.0
        for _ in 0..<count {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            oldSum += formatter.date(from: timestamp)!.timeIntervalSince1970
        }
        let oldTime = Date().timeIntervalSince(oldStart)
        let newStart = Date()
        var newSum = 0.0
        for index in 0..<count {
            newSum += ReadRow(id: String(index), author: "Bot", text: "Message", isUser: false, timestamp: timestamp).time
        }
        let newTime = Date().timeIntervalSince(newStart)
        XCTAssertEqual(newSum, oldSum, accuracy: 1)
        // Report, rather than assert, timings: shared CI scheduling varies.
        print("Timestamp benchmark: rows=\(count) legacy=\(oldTime)s current=\(newTime)s")
    }
}
