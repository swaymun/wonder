import XCTest
@testable import WonderPairing

final class ActivityLayoutTests: XCTestCase {
    private func row(_ i: Int, type: String = "commandExecution", output: String = "ok") -> ReadRow {
        let item = ReadItem(id:"item-\(i)",type:type,state:"completed",text:nil,createdAt:"1700000000000",payload:["output":.string(output),"arguments":.object(["input":.string(output)]),"command":.string("example"),"diffs":.array([.object(["path":.string("one"),"diff":.string("+one\n-two")])])])
        return ReadRow(id:"turn/item-\(i)",author:"Bot",text:"",isUser:false,timestamp:"1700000000000",turnId:"turn",item:item)
    }

    private func compaction(_ id: String, state: String = "completed", text: String? = "private summary") -> ReadRow {
        let item = ReadItem(id: id, type: "contextCompaction", state: state, text: text,
            createdAt: "1700000000000", payload: ["privateInstructions": .string("do not show")])
        return ReadRow(id: id, author: "Bot", text: text ?? "", isUser: false,
            timestamp: "1700000000000", turnId: "turn", item: item)
    }
    func testLargeActivityIsFlatAndKeepsStableIDsAcrossExpansion() {
        let rows=(0..<2000).map { row($0) }
        let groups=ChatFeedEntry.grouping(rows)
        XCTAssertEqual(groups.count,1)
        let collapsed=ChatFeedNode.visible(groups,expanded:[])
        XCTAssertEqual(collapsed.count,1)
        let expanded=ChatFeedNode.visible(groups,expanded:[groups[0].id])
        XCTAssertEqual(expanded.count,2001)
        XCTAssertEqual(Set(expanded.map(\.id)).count,expanded.count)
        XCTAssertEqual(expanded[0].id,collapsed[0].id)
        XCTAssertEqual(expanded[1].entryID,collapsed[0].id)
        XCTAssertEqual(ChatFeedNode.visible(groups,expanded:[]).map(\.id),collapsed.map(\.id))
    }
    func testSummariesNeverFormatLargeOutputOrDiffDetails() {
        for kind in ["commandExecution","fileChange","dynamicToolCall"] {
            let value=row(1,type:kind,output:String(repeating:"large output\n",count:10000))
            XCTAssertTrue(value.activitySummary!.details.isEmpty)
            XCTAssertFalse(value.activity!.details.isEmpty)
        }
    }
    func testFocusedItemKeepsSeparateAnchor() {
        let rows=(0..<3).map { row($0) }
        let groups=ChatFeedEntry.grouping(rows,focusedRowID:rows[1].id)
        XCTAssertEqual(groups.count,3)
        XCTAssertEqual(groups[1].id,rows[1].id)
    }

    func testRemovedActivityDetailOrFileAnchorMapsToItsSurvivingHeader() {
        let source = row(0)
        let entry = ChatFeedEntry.grouping([source]).first!
        let header = entry.id
        let nodes = [header]

        XCTAssertEqual(ChatFeedNode.survivingAnchor(for: "activity:" + source.id, entries: [entry], nodeIDs: nodes), header)
        XCTAssertEqual(ChatFeedNode.survivingAnchor(for: "file:" + header + ":preview", entries: [entry], nodeIDs: nodes), header)
        XCTAssertEqual(ChatFeedNode.survivingAnchor(for: source.id, entries: [entry], nodeIDs: nodes), header)
        XCTAssertNil(ChatFeedNode.survivingAnchor(for: "activity:missing", entries: [entry], nodeIDs: nodes))
        XCTAssertEqual(ChatFeedNode.survivingAnchor(for: header, entries: [entry], nodeIDs: nodes), header)
    }

    func testCompactionIsAStableStructuralSeparatorOutsideWorkingDisclosure() {
        let rows = [row(0), compaction("compact-1"), row(1), compaction("compact-2"), row(2)]
        let entries = ChatFeedEntry.grouping(rows)
        XCTAssertEqual(entries.map(\.id), ["turn/item-0", "compact-1", "turn/item-1", "compact-2", "turn/item-2"])
        XCTAssertEqual(entries.filter(\.isContextCompaction).map(\.id), ["compact-1", "compact-2"])
        XCTAssertFalse(entries[1].isActivity)
        XCTAssertFalse(entries[3].isActivity)
        XCTAssertEqual(ChatFeedEntry.latestActivityEntryIDs(entries), ["turn/item-2"])

        let collapsed = ChatFeedNode.visible(entries, expanded: [])
        XCTAssertEqual(collapsed.map(\.id), ["turn/item-0", "compact-1", "turn/item-1", "compact-2", "turn/item-2"])
        XCTAssertTrue(collapsed.contains { node in
            if case .compaction(let value) = node.content { return value.id == "compact-1" }
            return false
        })
        XCTAssertTrue(collapsed.contains { node in
            if case .compaction(let value) = node.content { return value.id == "compact-2" }
            return false
        })

        let expanded = ChatFeedNode.visible(entries, expanded: [entries[0].id])
        XCTAssertEqual(expanded.map(\.id), ["turn/item-0", "activity:turn/item-0", "compact-1", "turn/item-1", "compact-2", "turn/item-2"])
        XCTAssertEqual(ChatFeedNode.visible(entries, expanded: []).map(\.id), collapsed.map(\.id))
    }

    private func media(_ id: String, type: String, fileID: String, turn: String = "turn", author: String = "bot", phase: String? = nil) -> ReadRow {
        let file: ThreadValue = .object(["id": .string(fileID), "name": .string("Preview.png"),
            "mimeType": .string("image/png"), "state": .string("available"), "updatedAt": .string("now")])
        var payload: [String: ThreadValue] = ["result": .object(["content": .array([
            .object(["type": .string("wonderArtifact"), "file": file])])])]
        if let phase { payload["phase"] = .string(phase) }
        return ReadRow(id: id, author: author, text: "Here is the image.", isUser: false, timestamp: "1000", authorId: author,
            turnId: turn, item: ReadItem(id: id, type: type, state: "completed", text: "Here is the image.", createdAt: "1000", payload: payload))
    }

    private func files(_ nodes: [ChatFeedNode]) -> [String] {
        nodes.compactMap { if case .file(let file) = $0.content { return file.id }; return nil }
    }

    func testAllWorkingImagesStayCollapsedAndExpandBesideTheirSource() {
        let rows = ["imageView", "imageGeneration", "mcpToolCall", "dynamicToolCall", "functionCallOutput"].enumerated().map {
            media("work-\($0.offset)", type: $0.element, fileID: "image-\($0.offset)")
        }
        let entries = ChatFeedEntry.grouping(rows)
        XCTAssertEqual(entries.count, 1)
        let collapsed = ChatFeedNode.visible(entries, expanded: [])
        XCTAssertEqual(collapsed.map(\.id), ["work-0"])
        let expanded = ChatFeedNode.visible(entries, expanded: ["work-0"])
        XCTAssertEqual(files(expanded), (0..<5).map { "image-\($0)" })
        XCTAssertEqual(expanded.map(\.id), ["work-0"] + (0..<5).flatMap {
            ["activity:work-\($0)", "file:work-0:image-\($0)"]
        })
        XCTAssertEqual(ChatFeedNode.visible(entries, expanded: []).map(\.id), collapsed.map(\.id))
        XCTAssertEqual(ChatFeedNode.visible(entries, expanded: ["work-0"]).map(\.id), expanded.map(\.id))
    }

    func testFinalMessageMediaStaysVisibleWithoutPromotingOtherImages() {
        let rows = [media("draft", type: "imageView", fileID: "draft"),
            media("comment", type: "agentMessage", fileID: "comment", phase: "commentary"),
            media("reply", type: "agentMessage", fileID: "chosen", phase: "final_answer")]
        let entries = ChatFeedEntry.grouping(rows)
        let collapsed = ChatFeedNode.visible(entries, expanded: [])
        XCTAssertEqual(files(collapsed), ["chosen"])
        XCTAssertEqual(collapsed.map(\.id), ["draft", "reply", "file:reply:chosen"])
        XCTAssertEqual(files(ChatFeedNode.visible(entries, expanded: ["draft"])), ["draft", "comment", "chosen"])
    }

    func testExpansionStaysScopedToTurnAndGroupSpeakerAndDeduplicatesFiles() {
        let rows = [media("one", type: "imageView", fileID: "same"),
            media("replay", type: "dynamicToolCall", fileID: "same"),
            media("two", type: "imageView", fileID: "second", author: "another-bot"),
            media("three", type: "imageView", fileID: "third", turn: "next")]
        let entries = ChatFeedEntry.grouping(rows)
        XCTAssertEqual(entries.map(\.id), ["one", "two", "three"])
        XCTAssertEqual(files(ChatFeedNode.visible(entries, expanded: ["one"])), ["same"])
        XCTAssertEqual(files(ChatFeedNode.visible(entries, expanded: ["two"])), ["second"])
        let revised = ChatFeedEntry.grouping([media("one", type: "imageView", fileID: "replacement")])
        XCTAssertEqual(files(ChatFeedNode.visible(revised, expanded: ["one"])), ["replacement"])
        XCTAssertTrue(files(ChatFeedNode.visible([], expanded: ["one"])).isEmpty)
    }
}
