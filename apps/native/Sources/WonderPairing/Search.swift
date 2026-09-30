import Foundation

public struct SearchMessageFocus: Identifiable, Sendable {
    public let id = UUID()
    public let conversationID: String
    public let rowID: String
    public let scrollID: String
    public init(conversationID: String, rowID: String, scrollID: String) { self.conversationID = conversationID; self.rowID = rowID; self.scrollID = scrollID }
}
