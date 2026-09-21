import XCTest
import CryptoKit
@testable import WonderPairing
final class AttentionTests: XCTestCase {
    private func phoneRequest(_ method: String, _ params: [String: Any]) throws -> AttentionRequest {
        try JSONDecoder().decode(AttentionRequest.self, from: JSONSerialization.data(withJSONObject: [
            "approvalId":"phone-request", "actionNonce":"nonce", "resolutionIdempotencyKey":"identity",
            "method":method, "params":params
        ]))
    }
    private func response(_ request: AttentionRequest, _ choice: PhoneApprovalChoice, _ answers: [String: String] = [:]) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(request.responseJSON(for: choice, answers: answers)).utf8)) as! [String: Any]
    }
    func testPhoneCommandChoicesPreserveOnlyAdvertisedAmendmentsAndSessionScope() throws {
        let amend: [String: Any] = ["acceptWithExecpolicyAmendment":["execpolicy_amendment":["git", "status"]]]
        let network: [String: Any] = ["applyNetworkPolicyAmendment":["network_policy_amendment":["host":"example.com", "action":"allow"]]]
        let request = try phoneRequest("item/commandExecution/requestApproval", [
            "networkApprovalContext":["host":"example.com", "protocol":"https"],
            "additionalPermissions":["network":["enabled":true]],
            "availableDecisions":["acceptForSession", amend, network, ["unknown":true], "decline"]
        ])
        XCTAssertEqual(request.phoneChoices.count, 4)
        XCTAssertEqual(request.phoneChoices.first?.decision, "acceptForSession")
        XCTAssertFalse(request.phoneChoices.contains { $0.id == "accept" })
        XCTAssertTrue(request.permissionDetails.contains { $0.contains("example.com") && $0.contains("https") })
        XCTAssertTrue(request.permissionDetails.contains("Allow network access."))
        let saved = try JSONDecoder().decode(AttentionRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(saved.phoneChoices, request.phoneChoices)
        let choice = try XCTUnwrap(saved.phoneChoices.first { $0.structuredDecision != nil })
        XCTAssertTrue(choice.detail?.contains("\"git\" \"status\"") == true)
        let intent = DecisionIntent(request: saved, decision: choice.decision, responseJson: nil, structuredDecision: choice.structuredDecision)
        let payload = try JSONSerialization.jsonObject(with: intent.payload(issuedAtMs: 10, signature: "signed")) as! [String: Any]
        XCTAssertEqual(payload["decision"] as? NSDictionary, amend as NSDictionary)
        XCTAssertNil(try saved.responseJSON(for: choice, answers: [:]))
    }
    func testFileRequestWithoutChangesSupportsItsActualGrantRootContract() throws {
        let request = try phoneRequest("item/fileChange/requestApproval", ["grantRoot":"/project/reports", "reason":"Save the report"])
        XCTAssertEqual(request.phoneChoices.map(\.id), ["accept", "acceptForSession", "decline", "cancel"])
        XCTAssertTrue(request.permissionDetails.contains { $0.contains("/project/reports") && $0.contains("session") })
    }
    func testPermissionsGrantExactProfileAndDeclineNoAdditionalAccess() throws {
        let permissions: [String: Any] = ["fileSystem":["entries":[
            ["access":"write", "path":["type":"special", "value":["kind":"project_roots", "subpath":"reports"]]],
            ["access":"read", "path":["type":"glob_pattern", "pattern":"/pictures/*.jpg"]]
        ], "globScanMaxDepth":3], "network":["enabled":true]]
        let request = try phoneRequest("item/permissions/requestApproval", ["permissions":permissions])
        XCTAssertEqual(request.phoneChoices.map(\.decision), ["accept", "acceptForSession", "decline"])
        XCTAssertTrue(request.permissionDetails.contains { $0.contains("project folders/reports") })
        for choice in request.phoneChoices {
            let wire = try response(request, choice)
            XCTAssertEqual(wire["permissions"] as? NSDictionary, choice.id == "decline" ? [:] : permissions as NSDictionary)
            XCTAssertEqual(wire["scope"] as? String, choice.id == "allowSession" ? "session" : "turn")
        }
        let unsupported = try phoneRequest("item/permissions/requestApproval", ["permissions":["futureAccess":true]])
        XCTAssertEqual(unsupported.phoneChoices.map(\.id), ["decline"])
        XCTAssertNotNil(unsupported.unsupportedReason)
    }
    func testTypedMCPFormEnforcesValuesConstraintsAndWireTypes() throws {
        let request = try phoneRequest("mcpServer/elicitation/request", ["mode":"form", "requestedSchema":[
            "type":"object", "required":["count", "enabled", "name", "color", "choices"],
            "properties":[
                "count":["type":"integer", "minimum":1, "maximum":3],
                "enabled":["type":"boolean"],
                "name":["type":"string", "minLength":2, "maxLength":4, "writeOnly":true],
                "color":["type":"string", "oneOf":[["const":"r", "title":"Red"], ["const":"b", "title":"Blue"]]],
                "choices":["type":"array", "minItems":1, "maxItems":2, "items":["anyOf":[["const":"a", "title":"Alpha"], ["const":"b", "title":"Beta"]]]],
                "optional":["type":"string", "format":"email"]
            ]
        ]])
        XCTAssertNil(request.unsupportedReason)
        XCTAssertEqual(request.elicitationFields.count, 6)
        XCTAssertEqual(request.elicitationFields.first { $0.id == "color" }?.optionTitles["r"], "Red")
        XCTAssertEqual(request.elicitationFields.first { $0.id == "choices" }?.kind, .multiChoice)
        XCTAssertTrue(request.elicitationFields.first { $0.id == "name" }?.secret == true)
        let accept = try XCTUnwrap(request.phoneChoices.first { $0.id == "accept" })
        let valid = ["count":"2", "enabled":"false", "name":"A📸", "color":"r", "choices":"[\"a\"]"]
        XCTAssertTrue(request.canSubmit(choice: accept, answers: valid))
        let content = try XCTUnwrap(try response(request, accept, valid)["content"] as? [String: Any])
        XCTAssertEqual(content["count"] as? Int, 2)
        XCTAssertEqual(content["enabled"] as? Bool, false)
        XCTAssertEqual(content["choices"] as? [String], ["a"])
        XCTAssertNil(content["optional"])
        for (key, invalid) in [("count","4"), ("count","2.5"), ("count","nan"), ("enabled","yes"), ("name","a"), ("color","Red"), ("choices","[]"), ("choices","[\"a\",\"a\"]"), ("optional","bad-email")] {
            var answers = valid; answers[key] = invalid
            XCTAssertFalse(request.canSubmit(choice: accept, answers: answers), key + invalid)
            XCTAssertThrowsError(try request.responseJSON(for: accept, answers: answers))
        }
        let decline = try XCTUnwrap(request.phoneChoices.first { $0.id == "decline" })
        XCTAssertTrue(request.canSubmit(choice: decline, answers: [:]))
        XCTAssertNil(try response(request, decline)["content"])
    }
    func testMCPDefaultsTitledLegacyEnumsAndUnsupportedConstraintsAreHonest() throws {
        let request = try phoneRequest("mcpServer/elicitation/request", ["mode":"openai/form", "requestedSchema":[
            "type":"object", "properties":["theme":["type":"string", "enum":["dark","light"], "enumNames":["Dark theme","Light theme"], "default":"dark"]]
        ]])
        XCTAssertEqual(request.elicitationFields.first?.defaultValue, "dark")
        XCTAssertEqual(request.elicitationFields.first?.optionTitles["dark"], "Dark theme")
        for schema: [String: Any] in [
            ["type":"object", "properties":["secret":["type":"string", "pattern":"^[A-Z]+$"]]],
            ["type":"object", "properties":["nested":["type":"object", "properties":[:]]]],
            ["type":"object", "properties":[:], "required":["missing"]]
        ] {
            let unsupported = try phoneRequest("mcpServer/elicitation/request", ["mode":"form", "requestedSchema":schema])
            XCTAssertEqual(unsupported.phoneChoices.map(\.id), ["decline", "cancel"])
            XCTAssertNotNil(unsupported.unsupportedReason)
        }
    }
    func testChoiceAnswersAndDefaultsHonorStringConstraints() throws {
        for selection: [String: Any] in [
            ["enum":["a", "verylong@example.com", "bademail", "ok@x.io"]],
            ["oneOf":[["const":"a", "title":"Too short"], ["const":"verylong@example.com", "title":"Too long"],
                       ["const":"bademail", "title":"Invalid email"], ["const":"ok@x.io", "title":"Valid email"]]]
        ] {
            var field: [String: Any] = ["type":"string", "minLength":3, "maxLength":10, "format":"email"]
            field.merge(selection) { _, new in new }
            func form(_ field: [String: Any]) throws -> AttentionRequest {
                try phoneRequest("mcpServer/elicitation/request", ["mode":"form", "requestedSchema":[
                    "type":"object", "required":["contact"], "properties":["contact":field]
                ]])
            }
            let request = try form(field)
            let accept = try XCTUnwrap(request.phoneChoices.first { $0.id == "accept" })
            XCTAssertTrue(request.canSubmit(choice: accept, answers: ["contact":"ok@x.io"]))
            let content = try response(request, accept, ["contact":"ok@x.io"])["content"] as? [String: Any]
            XCTAssertEqual(content?["contact"] as? String, "ok@x.io")
            for invalid in ["a", "verylong@example.com", "bademail"] {
                XCTAssertFalse(request.canSubmit(choice: accept, answers: ["contact":invalid]))
                XCTAssertThrowsError(try request.responseJSON(for: accept, answers: ["contact":invalid]))
                field["default"] = invalid
                let invalidDefault = try form(field)
                XCTAssertEqual(invalidDefault.phoneChoices.map(\.id), ["decline", "cancel"])
                XCTAssertNotNil(invalidDefault.unsupportedReason)
            }
            field["default"] = "ok@x.io"
            let validDefault = try form(field)
            XCTAssertEqual(validDefault.elicitationFields.first?.defaultValue, "ok@x.io")
            XCTAssertNil(validDefault.unsupportedReason)
        }
    }
    func testMCPURLAndUnknownDynamicRequestsCanBeResolvedFromPhoneSafely() throws {
        let valid = try phoneRequest("mcpServer/elicitation/request", ["mode":"url", "url":"https://example.com/verify"])
        XCTAssertEqual(valid.elicitationURL?.host, "example.com")
        let accept = try XCTUnwrap(valid.phoneChoices.first { $0.id == "accept" })
        XCTAssertEqual(try response(valid, accept)["action"] as? String, "accept")
        for value in ["javascript:alert(1)", "file:///private/file", "https://user:password@example.com", "http://example.com"] {
            let unsafe = try phoneRequest("mcpServer/elicitation/request", ["mode":"url", "url":value])
            XCTAssertNil(unsafe.elicitationURL)
            XCTAssertEqual(unsafe.phoneChoices.map(\.id), ["decline", "cancel"])
        }
        let unknown = try phoneRequest("item/tool/call", ["tool":"unknown_tool", "arguments":["action":"anything"]])
        let decline = try XCTUnwrap(unknown.phoneChoices.first)
        XCTAssertEqual(decline.id, "decline"); XCTAssertEqual(decline.decision, "respond")
        XCTAssertEqual(try response(unknown, decline)["success"] as? Bool, false)
        XCTAssertNotNil(unknown.unsupportedReason)
    }
    func testStructuredDecisionCanonicalMatchesRustAndOldIntentsStillDecode() throws {
        let request = try phoneRequest("item/commandExecution/requestApproval", [:])
        let structured: TeachingJSONValue = .object(["z":.array([.string("quote\"/📸")]), "a":.object(["2":.string("two"), "10":.string("ten"), "A":.bool(true), "a":.bool(false)])])
        let intent = DecisionIntent(request: request, decision: "amendment", responseJson: nil, structuredDecision: structured)
        let restored = try JSONDecoder().decode(DecisionIntent.self, from: JSONEncoder().encode(intent))
        XCTAssertEqual(restored.structuredDecision, structured)
        let connection = SavedConnection(origin: "https://test.invalid", credential: Credential(sessionToken: "token", deviceId: "phone", csrfToken: "binding", hostInstallationId: "host", expiresAtMs: nil))
        let canonical = #"[{"a":{"10":"ten","2":"two","A":true,"a":false},"z":["quote\"/📸"]},"nonce","pending","identity",""]"#
        let expectedHash = SHA256.hash(data: Data(canonical.utf8)).map { String(format:"%02x", $0) }.joined()
        let transcript = String(decoding: try restored.transcript(path: "/approval", connection: connection, issuedAtMs: 1), as: UTF8.self)
        XCTAssertEqual(transcript.split(separator:"\n")[3], Substring(expectedHash))
        let legacy = try JSONDecoder().decode(DecisionIntent.self, from: Data(#"{"decision":"accept","actionNonce":"nonce","idempotencyKey":"old-id","responseJson":null}"#.utf8))
        XCTAssertNil(legacy.structuredDecision); XCTAssertEqual(legacy.decision, "accept")
        let body = try JSONSerialization.jsonObject(with: legacy.payload(issuedAtMs: 2, signature: "signed")) as! [String: Any]
        XCTAssertEqual(body["decision"] as? String, "accept")
    }
    func testComputerApprovalDescribesExactActionAndPersistsSignedChoice() throws {
        for (arguments, supported) in [
            (#"{"action":"screenshot"}"#, true),
            (#"{"action":"type","text":"Hello\nworld"}"#, true),
            (#"{"action":"click","x":1.5,"y":2}"#, true),
            (#"{"action":"key","keyCode":36,"modifiers":1048576}"#, true),
            (#"{"action":"focusApp","bundleId":"com.apple.Photos"}"#, true),
            (#"{"action":"click","x":1}"#, false),
            (#"{"action":"screenshot","text":"hidden action"}"#, false),
            (#"{"action":"key","keyCode":65536}"#, false),
            (#"{"action":"key","keyCode":36,"modifiers":1}"#, false),
            (#"{"action":"future"}"#, false),
            (#""opaque payload""#, false)
        ] {
            let data = Data("{\"approvalId\":\"runtime:2\",\"method\":\"item/tool/call\",\"actionNonce\":\"nonce\",\"params\":{\"tool\":\"wonder_computer_use\",\"arguments\":\(arguments)}}".utf8)
            let request = try JSONDecoder().decode(AttentionRequest.self, from: data)
            XCTAssertEqual(request.computerAction != nil, supported, arguments)
            XCTAssertTrue(request.supportsDecision) // Unsupported tools can always be declined.
            let restored = try JSONDecoder().decode(AttentionRequest.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(restored.computerAction != nil, supported, arguments)
            guard supported else { continue }
            XCTAssertNotNil(request.computerAction?.detail)
            for decision in ["accept", "decline"] {
                let intent = DecisionIntent(request: request, decision: decision, responseJson: nil)
                XCTAssertEqual(intent.decision, "respond")
                let response = try JSONSerialization.jsonObject(with: Data(intent.responseJson!.utf8)) as! [String: Any]
                XCTAssertEqual(response["success"] as? Bool, decision == "accept")
                XCTAssertEqual((response["contentItems"] as? [Any])?.count, 0)
                let saved = try JSONDecoder().decode(DecisionIntent.self, from: JSONEncoder().encode(intent))
                XCTAssertEqual(saved.idempotencyKey, intent.idempotencyKey)
                XCTAssertEqual(saved.responseJson, intent.responseJson)
            }
        }
    }
    func testRuntimeApprovalTargetMatchesRustDecodedPathWithoutChangingSavedDecision() throws {
        let saved = SavedConnection(origin: "https://test.invalid", credential: Credential(sessionToken: "token", deviceId: "phone", csrfToken: "binding", hostInstallationId: "host", expiresAtMs: nil))
        let original = DecisionIntent(request: try request(conversation: "group", params: [:]), decision: "accept", responseJson: nil)
        let intent = try JSONDecoder().decode(DecisionIntent.self, from: JSONEncoder().encode(original))
        for (id, escaped) in [
            ("14570-1788932349636470000:8", "14570%2D1788932349636470000%3A8"),
            ("runtime/%2F:8", "runtime%2F%252F%3A8")
        ] {
            let target = ApprovalResolutionTarget(approvalID: id)
            XCTAssertEqual(target.requestPath, "/api/v1/approvals/" + escaped + "/resolve")
            // Rust: Path(approval_id), format!("/api/v1/approvals/{approval_id}/resolve").
            let rustTarget = "/api/v1/approvals/" + (escaped.removingPercentEncoding ?? "") + "/resolve"
            XCTAssertEqual(target.signedTarget, rustTarget)
            XCTAssertEqual(target.signedTarget, "/api/v1/approvals/" + id + "/resolve")
            let canonical = try JSONSerialization.data(withJSONObject: ["accept", "exact-nonce", "pending", "exact-resolution", ""], options: [.withoutEscapingSlashes])
            let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            let expected = ["wonder-action-v1", "approval.resolve", rustTarget, digest, "exact-nonce", "binding", "phone", "host", "456", "pending"].joined(separator: "\n")
            XCTAssertEqual(String(decoding: try intent.transcript(path: target.signedTarget, connection: saved, issuedAtMs: 456), as: UTF8.self), expected)
        }
        XCTAssertEqual(intent.actionNonce, original.actionNonce)
        XCTAssertEqual(intent.idempotencyKey, original.idempotencyKey)
        XCTAssertEqual(intent.decision, "accept")
    }
    func testTrustedConversationMappingRoutesGroupChildAndOverridesThreadFallback() throws {
        let mapped = try request(conversation: "group", params: ["threadId": "child-thread", "conversationId": "spoofed", "command": "git status"])
        XCTAssertTrue(mapped.belongs(to: "group", isDirect: false, threadIDs: []))
        XCTAssertFalse(mapped.belongs(to: "other-group", isDirect: false, threadIDs: ["child-thread"]))
        XCTAssertFalse(mapped.belongs(to: "direct", isDirect: true, threadIDs: ["child-thread"]))
        XCTAssertFalse(mapped.belongs(to: "spoofed", isDirect: false, threadIDs: []))
        let restored = try JSONDecoder().decode(AttentionRequest.self, from: JSONEncoder().encode(mapped))
        XCTAssertEqual(restored.conversationId, "group")
        let decision = DecisionIntent(request: restored, decision: "accept", responseJson: nil)
        XCTAssertEqual(decision.actionNonce, "exact-nonce")
        XCTAssertEqual(decision.idempotencyKey, "exact-resolution")
    }
    func testLegacyUnmappedRequestMatchesOnlyExactDirectThread() throws {
        let legacy = try request(conversation: nil, params: ["threadId": "thread", "conversationId": "group", "cwd": "/shared/project"])
        XCTAssertNil(legacy.conversationId)
        XCTAssertTrue(legacy.belongs(to: "direct", isDirect: true, threadIDs: ["thread"]))
        XCTAssertFalse(legacy.belongs(to: "other", isDirect: true, threadIDs: ["other-thread"]))
        XCTAssertFalse(legacy.belongs(to: "group", isDirect: false, threadIDs: ["thread"]))
        let unmapped = try request(conversation: nil, params: ["cwd": "/shared/project"])
        XCTAssertFalse(unmapped.belongs(to: "direct", isDirect: true, threadIDs: []))
        XCTAssertFalse(unmapped.belongs(to: "group", isDirect: false, threadIDs: []))
        let direct = try request(conversation: "direct", params: [:])
        XCTAssertTrue(direct.belongs(to: "direct", isDirect: true, threadIDs: []))
    }
    private func request(conversation: String?, params: [String: String]) throws -> AttentionRequest {
        var json: [String: Any] = ["approvalId": "request", "method": "item/commandExecution/requestApproval",
            "actionNonce": "exact-nonce", "resolutionIdempotencyKey": "exact-resolution", "params": params]
        if let conversation { json["conversationId"] = conversation }
        return try JSONDecoder().decode(AttentionRequest.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func testQuestionAndPermissionAreDifferentAndDecisionSurvivesRenewal() throws {
        let request = try JSONDecoder().decode(AttentionRequest.self, from: Data("""
        {"approvalId":"request","method":"item/tool/requestUserInput","actionNonce":"nonce","params":{"questions":[{"id":"q","question":"Which day?","options":[{"label":"Friday"}]}],"isBlocking":false}}
        """.utf8))
        XCTAssertTrue(request.isQuestion); XCTAssertFalse(request.supportsDecision)
        XCTAssertEqual(request.params.isBlocking, false)
        let original = DecisionIntent(request: request, decision: "accept", responseJson: "{\"answers\":{\"q\":{\"answers\":[\"Friday\"]}}}")
        let intent = try JSONDecoder().decode(DecisionIntent.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(intent.idempotencyKey, original.idempotencyKey)
        let saved = SavedConnection(origin: "https://test.invalid", credential: Credential(sessionToken: "token", deviceId: "phone", csrfToken: "binding", hostInstallationId: "host", expiresAtMs: nil))
        let transcript = try intent.transcript(path: "/api/v1/approvals/request/resolve", connection: saved, issuedAtMs: 123)
        let canonical = try JSONSerialization.data(withJSONObject: ["accept", "nonce", "pending", intent.idempotencyKey, intent.responseJson!], options: [.withoutEscapingSlashes])
        let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(String(decoding: transcript, as: UTF8.self), ["wonder-action-v1", "approval.resolve", "/api/v1/approvals/request/resolve", digest, "nonce", "binding", "phone", "host", "123", "pending"].joined(separator: "\n"))
        let value = try JSONSerialization.jsonObject(with: intent.payload(issuedAtMs: 456, signature: "signature")) as! [String: Any]
        XCTAssertEqual(value["responseJson"] as? String, original.responseJson)
        XCTAssertEqual(value["idempotencyKey"] as? String, original.idempotencyKey)
    }
    func testAsyncAnswersValidateUTF8AndTheCombinedHostEnvelope() throws {
        func question(titles: [String]) throws -> AsyncQuestion {
            let value: [String: Any] = ["id": "q", "conversationId": "chat", "turnId": "turn", "itemId": "item",
                "questions": titles.map { ["title": $0] }, "state": "pending", "expiresAtMs": 9999999999999]
            return try JSONDecoder().decode(AsyncQuestion.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let single = try question(titles: ["Answer"])
        XCTAssertNil(AsyncAnswerIntent(answers: [String(repeating: "é", count: 4096)], skip: false).validationError(for: single))
        XCTAssertEqual(AsyncAnswerIntent(answers: [String(repeating: "é", count: 4096) + "x"], skip: false).validationError(for: single), .answerTooLong)
        XCTAssertEqual(AsyncAnswerIntent(answers: ["  "], skip: false).validationError(for: single), .answerRequired)
        XCTAssertEqual(AsyncAnswerIntent(answers: [], skip: false).validationError(for: single), .answerRequired)
        XCTAssertNil(AsyncAnswerIntent(answers: [], skip: true).validationError(for: single))
        XCTAssertEqual(AsyncAnswerIntent(answers: ["answer"], skip: true).validationError(for: single), .answerRequired)

        let many = try question(titles: Array(repeating: "Q", count: 8))
        var answers = Array(repeating: String(repeating: "a", count: 8192), count: 8)
        // 8 titles/newlines plus 7 separators take 30 bytes in the host body.
        answers[7] = String(repeating: "a", count: 8192 - 30)
        XCTAssertNil(AsyncAnswerIntent(answers: answers, skip: false).validationError(for: many))
        answers[7] += "a"
        XCTAssertEqual(AsyncAnswerIntent(answers: answers, skip: false).validationError(for: many), .responseTooLong)
    }

    func testAsyncQuestionHasNoRpcDecisionAndExpiresWithoutChoosingAnOption() throws {
        let question = try JSONDecoder().decode(AsyncQuestion.self, from: Data("""
        {"id":"q","conversationId":"chat","turnId":"turn","itemId":"item","questions":[{"title":"Which day?","options":["Friday","Saturday"]}],"state":"pending","expiresAtMs":1000}
        """.utf8))
        XCTAssertEqual(question.rowId, "turn/item")
        XCTAssertTrue(question.canAnswer(now: 999))
        XCTAssertFalse(question.canAnswer(now: 1000))
        let skipped = AsyncAnswerIntent(answers: [], skip: true)
        let restored = try JSONDecoder().decode(AsyncAnswerIntent.self, from: JSONEncoder().encode(skipped))
        XCTAssertTrue(restored.skip)
        XCTAssertTrue(restored.answers.isEmpty)
    }
    func testStructuredDecisionIsNeverSilentlyAllowed() throws {
        let value = try JSONDecoder().decode(DecisionValue.self, from: Data("{\"acceptWithExecpolicyAmendment\":{}}".utf8))
        XCTAssertNil(value.text)
    }
}
