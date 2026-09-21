import SwiftUI
import WonderPairing

struct MessageSearchResults: View {
    @ObservedObject var model: ConnectionModel
    let query: String
    @State private var page = PersistedSearchPage()
    @State private var activeScope: String?
    @State private var loading = false
    @State private var savedResults = false
    @State private var failure: String?
    @State private var requestID = UUID()
    @State private var opening: String?
    @State private var openTask: Task<Void, Never>?
    @State private var openRequestID = UUID()
    @State private var openFailure: [String: String] = [:]
    private var scope: String { model.assignmentScope + "\n" + query }
    private var refreshKey: String { scope + "\n" + model.searchEpoch + String(model.accessEnded) }
    private var visible: [PersistedSearchResult] {
        page.results.filter { result in
            guard let chat = model.chats.first(where: { $0.id == result.conversationId }), !chat.isArchived else { return false }
            return result.kind == "message" || (result.kind == "assistant_message" && chat.botId != nil)
        }
    }
    var body: some View {
        Section("Messages") {
            ForEach(visible, id: \.identity) { result in
                VStack(alignment: .leading, spacing: 6) {
                    Button { open(result) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title).font(.headline)
                            Text(result.plainSnippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(opening != nil || model.accessEnded)
                    if opening == result.identity { ProgressView("Finding message…") }
                    if let error = openFailure[result.identity] { Text(error).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            }
            if loading { ProgressView("Searching messages…") }
            else if visible.isEmpty { Text("No matching messages.").foregroundStyle(.secondary) }
            if savedResults { Text("Saved results. Reconnect to refresh.").font(.caption).foregroundStyle(.secondary) }
            if let failure { FailureDetails("Search unavailable", message: failure) }
            if page.nextCursor != nil { Button("Load more results") { Task { await load(more: true) } }.disabled(loading || model.accessEnded) }
            Button("Refresh results") { Task { await load() } }.disabled(loading || model.accessEnded)
        }
        .task(id: refreshKey) {
            if activeScope != scope { openRequestID = UUID(); openTask?.cancel(); opening = nil; activeScope = scope; openFailure = [:] }
            let id = UUID(); requestID = id; loading = false
            guard !model.accessEnded else { page = PersistedSearchPage(); failure = "Access has ended. Reconnect in Settings."; return }
            page = (try? model.cachedSearch(query: query)) ?? PersistedSearchPage()
            savedResults = !page.results.isEmpty
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard requestID == id else { return }
            await load()
        }
        .onDisappear { openRequestID = UUID(); openTask?.cancel(); opening = nil }
    }
    @MainActor private func load(more: Bool = false) async {
        guard !model.accessEnded else { return }
        let id = UUID(), requestedScope = scope, cursor = more ? page.nextCursor : nil
        requestID = id; loading = true; failure = nil
        defer { if requestID == id { loading = false } }
        do {
            var fresh: PersistedSearchPage
            var replacing = !more
            do { fresh = try await model.fetchSearch(query: query, cursor: cursor) }
            catch PairingFailure.response(400) where cursor != nil {
                fresh = try await model.fetchSearch(query: query, cursor: nil); replacing = true
            }
            guard requestID == id, scope == requestedScope, !model.accessEnded, !Task.isCancelled else { return }
            if replacing { page = fresh } else { page.append(fresh) }
            savedResults = false
            do { try model.saveSearch(page, query: query) }
            catch { failure = "Results loaded, but could not be saved for offline use. Free some storage and refresh." }
        } catch {
            guard requestID == id, scope == requestedScope, !Task.isCancelled else { return }
            savedResults = !page.results.isEmpty
            if query.utf8.count > 256 { failure = "Use a shorter search." }
            else { failure = "Your Mac could not refresh these results. Reconnect and try again." }
        }
    }
    private func open(_ result: PersistedSearchResult) {
        let id = UUID(); openRequestID = id
        opening = result.identity; openFailure[result.identity] = nil
        openTask = Task {
            defer { if openRequestID == id { opening = nil } }
            do { try await model.openSearchMessage(result) }
            catch {
                if openRequestID == id, !Task.isCancelled { openFailure[result.identity] = (error as? SearchOpenFailure)?.message ?? "Your Mac is unavailable. Reconnect and try again." }
            }
        }
    }
}

enum SearchOpenFailure: Error {
    case unavailable, moreHistory, queued
    var message: String {
        switch self {
        case .unavailable: "This message is no longer available. Refresh the results."
        case .queued: "This message is waiting in Queue. Open its chat and choose Queue to view it."
        case .moreHistory: "This message is further back. Tap again to continue loading its saved history."
        }
    }
}
