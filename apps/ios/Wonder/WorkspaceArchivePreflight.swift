import Foundation
import ImageIO

/// Inspects ZIP metadata without expanding an untrusted publication or model.
/// The reader and Model I/O only see files that pass these resource bounds.
enum WorkspaceArchivePreflight {
    enum Kind: Equatable { case epub, usdz }

    enum Failure: LocalizedError {
        case invalid, tooLarge, unsupported

        var errorDescription: String? {
            switch self {
            case .invalid: "This archive is damaged or contains an unsafe path."
            case .tooLarge: "This archive expands beyond Wonder’s preview limit."
            case .unsupported: "This archive uses encryption or a format Wonder cannot preview."
            }
        }
    }

    static func validate(_ data: Data, as kind: Kind) throws {
        let bytes = [UInt8](data)
        let expandedLimit = kind == .epub ? 8 * 1024 * 1024 : 2 * 1024 * 1024
        guard bytes.count >= 22, bytes.count <= expandedLimit else { throw Failure.tooLarge }

        func u16(_ at: Int) throws -> Int {
            guard at >= 0, at + 2 <= bytes.count else { throw Failure.invalid }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        func u32(_ at: Int) throws -> Int {
            guard at >= 0, at + 4 <= bytes.count else { throw Failure.invalid }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }

        let start = max(0, bytes.count - 65_557)
        var end: Int?
        for at in stride(from: bytes.count - 22, through: start, by: -1) {
            if (try? u32(at)) == 0x06054b50,
               let commentLength = try? u16(at + 20),
               at + 22 + commentLength == bytes.count {
                end = at
                break
            }
        }
        guard let end else { throw Failure.invalid }
        guard try u16(end + 4) == 0, (try u16(end + 6)) == 0 else { throw Failure.unsupported }
        let diskEntries = try u16(end + 8)
        let entryCount = try u16(end + 10)
        guard diskEntries == entryCount, entryCount > 0, entryCount <= 512 else { throw Failure.tooLarge }
        let directorySize = try u32(end + 12)
        let directoryOffset = try u32(end + 16)
        guard directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF,
              directoryOffset <= end, directorySize <= end - directoryOffset else { throw Failure.unsupported }

        var cursor = directoryOffset
        var names = Set<String>()
        var expanded = 0
        var firstName: String?
        var firstPayload: Range<Int>?
        var firstMethod: Int?
        var firstOffset: Int?
        var firstExtraLength: Int?
        var hasContainer = false
        var storedModelEntries: [(name: String, range: Range<Int>)] = []
        for _ in 0..<entryCount {
            guard try u32(cursor) == 0x02014b50, cursor + 46 <= bytes.count else { throw Failure.invalid }
            let flags = try u16(cursor + 8)
            let method = try u16(cursor + 10)
            let compressed = try u32(cursor + 20)
            let uncompressed = try u32(cursor + 24)
            let nameLength = try u16(cursor + 28)
            let extraLength = try u16(cursor + 30)
            let commentLength = try u16(cursor + 32)
            let localOffset = try u32(cursor + 42)
            let unixMode = (try u32(cursor + 38)) >> 16
            let recordEnd = cursor + 46 + nameLength + extraLength + commentLength
            guard recordEnd <= directoryOffset + directorySize,
                  nameLength > 0, compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF,
                  localOffset != 0xFFFF_FFFF, flags & 1 == 0,
                  unixMode & 0o170000 != 0o120000 else { throw Failure.unsupported }
            guard method == 0 || (kind == .epub && method == 8) else { throw Failure.unsupported }
            let nameData = Data(bytes[(cursor + 46)..<(cursor + 46 + nameLength)])
            guard let name = String(data: nameData, encoding: .utf8), safe(name), names.insert(name.lowercased()).inserted else { throw Failure.invalid }
            if firstName == nil { firstName = name; firstMethod = method; firstOffset = localOffset }
            if name == "META-INF/container.xml" { hasContainer = true }
            if name == "META-INF/encryption.xml" { throw Failure.unsupported }
            guard uncompressed <= 2 * 1024 * 1024,
                  compressed == 0 ? uncompressed == 0 : uncompressed <= compressed * 100,
                  expanded <= expandedLimit - uncompressed else { throw Failure.tooLarge }
            expanded += uncompressed

            guard try u32(localOffset) == 0x04034b50,
                  (try u16(localOffset + 6)) == flags,
                  (try u16(localOffset + 8)) == method else { throw Failure.invalid }
            let localNameLength = try u16(localOffset + 26)
            let localExtraLength = try u16(localOffset + 28)
            if firstExtraLength == nil { firstExtraLength = localExtraLength }
            let payloadStart = localOffset + 30 + localNameLength + localExtraLength
            guard localNameLength == nameLength, payloadStart <= directoryOffset,
                  compressed <= directoryOffset - payloadStart,
                  Data(bytes[(localOffset + 30)..<(localOffset + 30 + localNameLength)]) == nameData else { throw Failure.invalid }
            if firstPayload == nil { firstPayload = payloadStart..<(payloadStart + compressed) }
            if kind == .usdz && !name.hasSuffix("/") {
                storedModelEntries.append((name, payloadStart..<(payloadStart + compressed)))
            }
            cursor = recordEnd
        }
        guard cursor == directoryOffset + directorySize else { throw Failure.invalid }
        if kind == .epub {
            guard firstName == "mimetype", firstMethod == 0, firstOffset == 0,
                  firstExtraLength == 0, hasContainer,
                  let firstPayload,
                  Data(bytes[firstPayload]) == Data("application/epub+zip".utf8) else { throw Failure.invalid }
        } else {
            try validateSelfContainedUSDZ(storedModelEntries, bytes: bytes)
        }
    }

    private static func validateSelfContainedUSDZ(_ entries: [(name: String, range: Range<Int>)],
                                                   bytes: [UInt8]) throws {
        let names = Set(entries.map { $0.name.lowercased() })
        guard entries.filter({ $0.name.lowercased().hasSuffix(".usda") }).count == 1 else {
            // Binary USD layers can carry opaque external asset references.
            throw Failure.unsupported
        }
        var pixels = 0
        for entry in entries {
            let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
            switch ext {
            case "usda":
                guard let source = String(data: Data(bytes[entry.range]), encoding: .utf8),
                      !source.contains("\0") else { throw Failure.invalid }
                let pieces = source.split(separator: "@", omittingEmptySubsequences: false)
                guard pieces.count.isMultiple(of: 2) == false else { throw Failure.invalid }
                for index in stride(from: 1, to: pieces.count, by: 2) {
                    let target = String(pieces[index])
                    guard safe(target), !target.hasPrefix("/"), !target.contains(":") else {
                        throw Failure.unsupported
                    }
                    let parent = (entry.name as NSString).deletingLastPathComponent
                    let resolved = parent.isEmpty ? target : parent + "/" + target
                    guard names.contains(resolved.lowercased()) else { throw Failure.unsupported }
                }
            case "png", "jpg", "jpeg":
                let data = Data(bytes[entry.range])
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = props[kCGImagePropertyPixelWidth] as? Int,
                      let height = props[kCGImagePropertyPixelHeight] as? Int,
                      (1...2_048).contains(width), (1...2_048).contains(height),
                      width * height <= 2_000_000,
                      pixels <= 2_000_000 - width * height else { throw Failure.tooLarge }
                pixels += width * height
            default:
                throw Failure.unsupported
            }
        }
    }

    private static func safe(_ name: String) -> Bool {
        guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0") else { return false }
        let lowered = name.lowercased()
        guard !lowered.contains("%2e"), !lowered.contains("%2f"), !lowered.contains("%5c") else { return false }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.enumerated().allSatisfy { index, part in
            !part.isEmpty || (index == parts.count - 1 && name.hasSuffix("/"))
        } && parts.allSatisfy { $0 != "." && $0 != ".." }
    }
}
