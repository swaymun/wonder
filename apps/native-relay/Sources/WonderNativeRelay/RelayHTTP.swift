import Foundation

public struct RelayRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let method: String
    public let path: String
    public let sessionToken: String
    public let csrfToken: String
    public let body: String

    private enum CodingKeys: String, CodingKey { case requestId, method, path, sessionToken, csrfToken, body }

    public init(requestId: String, method: String, path: String, sessionToken: String, csrfToken: String, body: String = "") throws {
        guard !requestId.isEmpty, !method.isEmpty, path.hasPrefix("/"), body.utf8.count <= 24 * 1024 else { throw RelayError.invalidRequest }
        self.requestId = requestId; self.method = method; self.path = path
        self.sessionToken = sessionToken; self.csrfToken = csrfToken; self.body = body
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestId: values.decode(String.self, forKey: .requestId),
            method: values.decode(String.self, forKey: .method),
            path: values.decode(String.self, forKey: .path),
            sessionToken: values.decode(String.self, forKey: .sessionToken),
            csrfToken: values.decode(String.self, forKey: .csrfToken),
            body: values.decodeIfPresent(String.self, forKey: .body) ?? ""
        )
    }
}

public struct RelayResponse: Codable, Equatable, Sendable {
    public let requestId: String
    public let status: Int
    public let body: String

    private enum CodingKeys: String, CodingKey { case requestId, status, body }

    public init(requestId: String, status: Int, body: String = "") throws {
        guard !requestId.isEmpty, body.utf8.count <= 24 * 1024 else { throw RelayError.invalidRequest }
        self.requestId = requestId; self.status = status; self.body = body
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestId: values.decode(String.self, forKey: .requestId),
            status: values.decode(Int.self, forKey: .status),
            body: values.decodeIfPresent(String.self, forKey: .body) ?? ""
        )
    }
}

public enum RelayJSONCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
}

/// The stream handshake is length-prefixed once by the daemon adapter. Noise
/// transport frames returned by `RelaySession.sealFrame` already contain their
/// own four-byte prefix and must not be wrapped a second time.
public enum RelayHandshakeFraming {
    public static func encode(_ message: Data) throws -> Data {
        guard !message.isEmpty, message.count <= 1024 else { throw RelayError.invalidHandshakeMessage }
        let count = UInt32(message.count)
        var frame = Data(count.bytes)
        frame.append(message)
        return frame
    }

    public static func decode(_ frame: Data) throws -> Data {
        guard frame.count >= 4 else { throw RelayError.invalidFrame }
        let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= 1024, frame.count == 4 + Int(length) else { throw RelayError.invalidFrame }
        return frame.dropFirst(4)
    }
}

private extension UInt32 {
    var bytes: [UInt8] {
        [UInt8(truncatingIfNeeded: self >> 24), UInt8(truncatingIfNeeded: self >> 16), UInt8(truncatingIfNeeded: self >> 8), UInt8(truncatingIfNeeded: self)]
    }
}
