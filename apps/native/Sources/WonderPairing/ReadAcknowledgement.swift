import Foundation
import CoreGraphics

/// This is the snapshot that was laid out on screen, never the latest global cursor.
public struct VisibleReadReceipt: Equatable, Sendable {
    public let conversationId: String
    public let hostEpoch: String
    public let readThroughSequence: UInt64
    public init(snapshot: ConversationSnapshot) {
        conversationId = snapshot.conversationId
        hostEpoch = snapshot.hostEpoch
        readThroughSequence = snapshot.lastSequence
    }
    public init?(group: GroupRead) {
        guard let epoch = group.hostEpoch, let sequence = group.lastSequence, group.hasUnread != nil else { return nil }
        conversationId = group.conversationId; hostEpoch = epoch; readThroughSequence = sequence
    }
    public func requestBody(isGroup: Bool = false) throws -> Data {
        struct Request: Encodable {
            let markRead = true
            let hostEpoch: String
            let readThroughSequence: UInt64
        }
        if isGroup {
            struct GroupRequest: Encodable { let hostEpoch: String; let readThroughSequence: UInt64 }
            return try JSONEncoder().encode(GroupRequest(hostEpoch: hostEpoch, readThroughSequence: readThroughSequence))
        }
        return try JSONEncoder().encode(Request(hostEpoch: hostEpoch, readThroughSequence: readThroughSequence))
    }
}

/// A covering sheet invalidates an in-flight read even if dismissed before its reply.
public struct ReadPresentationFence: Sendable {
    public private(set) var isCovered = false
    public private(set) var revision: UInt64 = 0
    public init() {}
    public mutating func setCovered(_ covered: Bool) {
        guard covered != isCovered else { return }
        isCovered = covered; revision &+= 1
    }
    public func acceptsReply(startedAt revision: UInt64) -> Bool { !isCovered && self.revision == revision }
}

public enum ReadVisibility {
    /// A long final message counts only when its end reaches the actual viewport.
    /// Merely constructing the message's VStack, or seeing its beginning, is insufficient.
    public static func latestEndIsVisible(frame: CGRect, viewport: CGRect) -> Bool {
        !frame.isEmpty && !viewport.isEmpty && !frame.isNull && !viewport.isNull &&
        frame.maxY >= viewport.minY && frame.maxY <= viewport.maxY &&
        frame.maxX > viewport.minX && frame.minX < viewport.maxX
    }
}

extension ProjectionState {
    @discardableResult public mutating func applyGroupReadAcknowledgement(_ reply: GroupRead, visible: VisibleReadReceipt, startedAtSequence: UInt64) -> Bool {
        guard reply.conversationId == visible.conversationId, hostEpoch == visible.hostEpoch,
            lastSequence == startedAtSequence, !dirty.contains(reply.conversationId),
            var current = groups[reply.conversationId], current.id == reply.id,
            VisibleReadReceipt(group: current) == visible, let unread = reply.hasUnread,
            let index = summaries.firstIndex(where: { $0.id == reply.conversationId }) else { return false }
        current.hasUnread = unread
        groups[reply.conversationId] = current
        summaries[index] = current.summary
        return true
    }

    /// Late acknowledgements must not replace a newer summary or clear an invalidated snapshot.
    @discardableResult public mutating func applyReadAcknowledgement(_ reply: ChatSummary, visible: VisibleReadReceipt, startedAtSequence: UInt64) -> Bool {
        guard reply.id == visible.conversationId, hostEpoch == visible.hostEpoch,
            lastSequence == startedAtSequence, !dirty.contains(reply.id),
            let snapshot = snapshots[reply.id], VisibleReadReceipt(snapshot: snapshot) == visible,
            let index = summaries.firstIndex(where: { $0.id == reply.id }) else { return false }
        let current = summaries[index]
        summaries[index] = ChatSummary(conversationId: current.conversationId, botId: current.botId,
            title: current.title, lastMessagePreview: current.lastMessagePreview, lastMessageAt: current.lastMessageAt,
            messageCount: current.messageCount, deliveryState: current.deliveryState, hasUnread: reply.hasUnread,
            isArchived: current.isArchived, isPinned: current.isPinned)
        return true
    }
}
