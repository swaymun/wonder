import XCTest
@testable import WonderPairing

final class JSONFormattingTests: XCTestCase {
    private func formatted(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .formatted(let value) = JSONFormatter.format(text) else {
            XCTFail("expected valid JSON", file: file, line: line); return ""
        }
        return value
    }
    private func error(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> JSONFormatError {
        guard case .invalid(let value) = JSONFormatter.format(text) else {
            XCTFail("expected invalid JSON", file: file, line: line)
            return JSONFormatError(line: 0, column: 0, message: "")
        }
        return value
    }

    func testKeyOrderAndDuplicateKeysArePreserved() {
        XCTAssertEqual(formatted(#"{"z":1,"a":2,"m":{"b":true,"a":null},"a":3}"#), """
        {
          "z": 1,
          "a": 2,
          "m": {
            "b": true,
            "a": null
          },
          "a": 3
        }
        """)
    }

    func testBigNumbersAndEscapesKeepTheirExactText() {
        let out = formatted(#"[12345678901234567890123, 0.10000000000000000555, 1E+400, -0, 1.50, "\u00e9\n\"\/"]"#)
        for expected in ["12345678901234567890123,", "0.10000000000000000555,", "1E+400,", "-0,", "1.50,", #""\u00e9\n\"\/""#] {
            XCTAssertTrue(out.contains(expected), expected)
        }
    }

    func testUnicodeStaysAsWritten() {
        let out = formatted(#"{"名前":"日本語 🙂","e":"é"}"#)
        XCTAssertTrue(out.contains(#""名前": "日本語 🙂""#))
        XCTAssertTrue(out.contains(#""e": "é""#))
    }

    func testNestedArraysEmptyContainersAndScalars() {
        XCTAssertEqual(formatted("[[1,[2,[]]],{},[ ]]"), """
        [
          [
            1,
            [
              2,
              []
            ]
          ],
          {},
          []
        ]
        """)
        XCTAssertEqual(formatted("  42 \n"), "42")
        XCTAssertEqual(formatted("\"x\""), "\"x\"")
        XCTAssertEqual(formatted("\u{FEFF}null"), "null")
    }

    func testFormattedOutputIsIdempotent() {
        let once = formatted(#"{"a":[1,{"b":[]}],"c":"d"}"#)
        XCTAssertEqual(formatted(once), once)
    }

    func testInvalidJSONReportsLineColumnAndReason() {
        let missingComma = error("{\n  \"a\": 1\n  \"b\": 2\n}")
        XCTAssertEqual(missingComma.line, 3)
        XCTAssertEqual(missingComma.column, 3)
        XCTAssertEqual(missingComma.summary, "Line 3, column 3: expected a comma or the end of the object")

        XCTAssertEqual(error("[1,]").column, 4)
        XCTAssertEqual(error("{\"a\":}").message, "expected a value")
        XCTAssertEqual(error("{'a':1}").message, "expected a quoted name")
        XCTAssertEqual(error("[1, 2").message, "the file ends before the JSON is complete")
        XCTAssertEqual(error("{} x").message, "there is extra text after the JSON value")
        XCTAssertEqual(error("\"abc").message, "this text never closes")
        XCTAssertEqual(error("[01]").message, "expected a comma or the end of the list")
        XCTAssertEqual(error("[1.]").message, "digits are missing after the decimal point")
        XCTAssertEqual(error("[\"\\q\"]").message, "an unknown escape")
        XCTAssertEqual(error("[\"a\nb\"]").message, "a line break or control character inside text")
        XCTAssertEqual(error("").message, "the file ends before the JSON is complete")
    }

    func testColumnCountsCharactersNotBytes() {
        XCTAssertEqual(error("[\"日本\" x]").column, 7)
    }

    func testSizeAndDepthCapsFailInsteadOfHanging() {
        XCTAssertEqual(JSONFormatter.format("[1,2,3]", maxBytes: 4), .tooLarge)
        XCTAssertTrue(error(String(repeating: "[", count: JSONFormatter.maxDepth + 1)).message.contains("levels deep"))
        let atLimit = String(repeating: "[", count: JSONFormatter.maxDepth) + String(repeating: "]", count: JSONFormatter.maxDepth)
        if case .formatted = JSONFormatter.format(atLimit) {} else { XCTFail("depth at the limit is allowed") }
    }

    func testHighlightingColoursKeysAndStaysPlainWhenHuge() throws {
        let lines = try XCTUnwrap(JSONFormatter.highlightedLines("{\n  \"a\": 1\n}"))
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].contains { $0.role != nil })
        XCTAssertNil(JSONFormatter.highlightedLines("[1,2,3]", maxBytes: 3))
    }

    func testJSONLSkipsBlankLinesKeepsLineNumbersAndFlagsInvalidLines() {
        let doc = JSONLDocument(parsing: "{\"a\":1}\n\n   \nnot json\r\n[1,2]\n")
        XCTAssertEqual(doc.records.map(\.line), [1, 4, 5])
        XCTAssertEqual(doc.records[0].formatted, "{\n  \"a\": 1\n}")
        XCTAssertNil(doc.records[1].formatted)
        XCTAssertEqual(doc.records[1].raw, "not json")
        XCTAssertEqual(doc.records[1].error?.column, 1)
        XCTAssertEqual(doc.records[2].formatted, "[\n  1,\n  2\n]")
        XCTAssertEqual(doc.omittedLines, 0)
        XCTAssertEqual(doc.shownText, "{\n  \"a\": 1\n}\n\nnot json\n\n[\n  1,\n  2\n]")
    }

    func testJSONLCapsRecordCountAndRecordSize() {
        let lines = (1...10).map { "{\"n\":\($0)}" }.joined(separator: "\n")
        let capped = JSONLDocument(parsing: lines, maxRecords: 3)
        XCTAssertEqual(capped.records.count, 3)
        XCTAssertEqual(capped.omittedLines, 7)

        let big = "{\"v\":\"" + String(repeating: "x", count: 100) + "\"}"
        let doc = JSONLDocument(parsing: big + "\n{\"ok\":1}", maxRecordBytes: 50)
        XCTAssertTrue(doc.records[0].isOversize)
        XCTAssertNil(doc.records[0].formatted)
        XCTAssertNotNil(doc.records[1].formatted)

        let long = JSONLDocument(parsing: String(repeating: "y", count: 9_000))
        XCTAssertLessThanOrEqual(long.records[0].raw.count, JSONLDocument.rawDisplayLimit + 1)
    }

    func testJSONLDropsTheLineAFileCutOffMidway() {
        let doc = JSONLDocument(parsing: "{\"a\":1}\n{\"b\":", isTruncated: true)
        XCTAssertEqual(doc.records.map(\.line), [1])
        XCTAssertTrue(doc.droppedPartialLine)
        let whole = JSONLDocument(parsing: "{\"a\":1}\n", isTruncated: true)
        XCTAssertFalse(whole.droppedPartialLine)
        XCTAssertEqual(whole.records.count, 1)
    }
}
