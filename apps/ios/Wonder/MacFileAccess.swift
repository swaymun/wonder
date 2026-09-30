import SwiftUI
import WonderPairing

/// This browser lists the paired Mac, independently of the device's Files app.
struct MacLocationBrowser: View {
    let model: ConnectionModel
    let title: String
    var foldersOnly = false
    var choose: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var page: MacLocationPage?
    @State private var entries: [MacLocationPage.Entry] = []
    @State private var nextOffset: Int?
    @State private var requestedPath: String?
    @State private var showHidden = false
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            List {
                if let page {
                    Section {
                        if let parent = page.parentPath { Button("Up one folder", systemImage: "arrow.up") { Task { await load(parent) } } }
                        Text(page.path).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    } header: { Text("On your Mac") }
                    ForEach(entries) { entry in
                        if entry.isDirectory {
                            Button { Task { await load(entry.path) } } label: {
                                HStack { Label(entry.name, systemImage: "folder"); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                            }.foregroundStyle(.primary)
                        } else if !foldersOnly {
                            Button { guard !busy else { return }; choose(entry.path, false); dismiss() } label: { Label(entry.name, systemImage: "doc") }.foregroundStyle(.primary)
                        }
                    }
                    if nextOffset != nil { Button("Load more") { Task { await load(page.path, more: true) } } }
                    if entries.isEmpty && !busy && failure == nil { Text("This folder is empty").foregroundStyle(.secondary) }
                }
                if let failure { FailureDetails(message: failure); Button("Try again") { Task { await load(requestedPath) } } }
            }
            .overlay { if page == nil && busy { ProgressView("Loading folders…") } }
            .overlay(alignment: .topTrailing) {
                ProgressView().controlSize(.small).padding()
                    .opacity(busy && page != nil ? 1 : 0).allowsHitTesting(false)
                    .accessibilityLabel("Loading folders").accessibilityHidden(!busy || page == nil)
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Menu { Button("Home", systemImage: "house") { Task { await load(nil) } }; Toggle("Show hidden files", isOn: $showHidden) } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("View options") }.disabled(busy) }
            }
            .safeAreaInset(edge: .bottom) {
                if let page {
                    Button("Choose this folder") { choose(page.path, true); dismiss() }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity).padding()
                        .background(.bar).disabled(busy || failure != nil)
                }
            }
            .task { if page == nil { await load(nil) } }
            .onChange(of: showHidden) { _, _ in Task { await load(page?.path) } }
        }
    }
    private func load(_ path: String?, more: Bool = false) async {
        guard !busy else { return }; busy = true; failure = nil; requestedPath = path; defer { busy = false }
        var url = URLComponents(); url.path = "/api/v1/filesystem"
        url.queryItems = [URLQueryItem(name: "showHidden", value: String(showHidden)), URLQueryItem(name: "offset", value: String(more ? nextOffset ?? 0 : 0))]
        if let path { url.queryItems?.append(URLQueryItem(name: "path", value: path)) }
        do {
            let result: MacLocationPage = try await model.manage(url.string!)
            if more {
                guard result.path == page?.path else { return }
                let known = Set(entries.map(\.id)); entries += result.entries.filter { !known.contains($0.id) }
            } else { entries = result.entries }
            page = result
            let previous = more ? nextOffset : nil
            nextOffset = result.nextOffset == previous ? nil : result.nextOffset
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if case PairingFailure.response(let status) = error {
                switch status {
                case 401: failure = "This device’s access has ended. Reconnect in Settings."
                case 403: failure = "This location is protected or unavailable to Wonder. Choose another folder."
                case 404: failure = "This folder moved or was removed. Go up or return Home to choose another location."
                case 400, 422: failure = "This location cannot be opened as a folder. Choose another location."
                default: failure = "Your Mac could not open this folder. Try again or choose another location."
                }
            } else { failure = "Your Mac could not be reached. Check its connection and try again." }
        }
    }
}

struct BotFolderRequest: Decodable, Identifiable, Sendable {
    let id: String
    let botId: String
    let path: String
    let access: String
    let useAsWorkingDirectory: Bool
    let state: String
}

/// Only authenticated owners can approve; the Bot merely proposes the folder.
struct FolderRequestsView: View {
    @ObservedObject var model: ConnectionModel
    let botID: String
    @State private var requests: [BotFolderRequest] = []
    @State private var busy: String?
    @State private var failure: String?
    @State private var stale = false
    @State private var loadedScope: String?
    @Environment(\.scenePhase) private var scenePhase
    private var scope: String { model.assignmentScope + ":" + botID }
    private var endpoint: String { "/api/v1/bots/" + ConnectionModel.escape(botID) + "/file-access/requests" }
    private var visibleRequests: [BotFolderRequest] {
        Array(requests.lazy.filter { $0.state == "pending" }.prefix(4))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(visibleRequests) { request in
                FolderRequestCard(
                    request: request,
                    status: status(for: request),
                    busy: busy == request.id,
                    disabled: busy != nil || stale || loadedScope != scope || model.accessEnded,
                    resolve: { accepted in Task { await resolve(request, accepted: accepted) } })
            }
            if let failure { FailureDetails("Folder request unavailable", message: failure) }
        }
        .onChange(of: scope) { _, _ in requests = []; failure = nil; stale = false; busy = nil; loadedScope = nil }
        .task(id: scope + ":" + String(scenePhase == .active)) {
            guard !model.previewMode, !model.accessEnded, scenePhase == .active else { return }
            while !Task.isCancelled, !model.accessEnded {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private func status(for request: BotFolderRequest) -> String {
        request.useAsWorkingDirectory
            ? "Approve this folder as the Workspace for the next turn."
            : "Approve this folder to grant access."
    }
    private func refresh() async {
        let expected = scope
        do {
            let updated: [BotFolderRequest] = try await model.manage(endpoint)
            guard !Task.isCancelled, expected == scope, !model.accessEnded else { return }
            requests = updated; loadedScope = expected; stale = false; failure = nil
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), expected == scope else { return }
            stale = true
            // Empty polling must not manufacture a folder request or an error
            // banner. Retain known requests, but require a fresh read to decide.
            if !visibleRequests.isEmpty { failure = "Can’t reach Wonder on your Mac. Reconnecting…" }
        }
    }
    private func resolve(_ request: BotFolderRequest, accepted: Bool) async {
        guard !stale, busy == nil, loadedScope == scope, !model.accessEnded else { return }
        let expected = scope
        busy = request.id; failure = nil
        defer { if expected == scope { busy = nil } }
        do {
            struct Decision: Encodable { let accepted: Bool }
            struct Empty: Decodable, Sendable {}
            let _: Empty = try await model.manage(endpoint + "/" + ConnectionModel.escape(request.id), method: "POST", body: JSONEncoder().encode(Decision(accepted: accepted)))
            guard !Task.isCancelled, expected == scope else { return }
            await refresh()
        } catch {
            guard !Task.isCancelled, expected == scope else { return }
            stale = true
            failure = "Wonder couldn’t confirm your choice. Reconnecting to check the request…"
        }
    }
}

struct FolderRequestCard: View {
    let request: BotFolderRequest
    let status: String
    let busy: Bool
    let disabled: Bool
    let resolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.useAsWorkingDirectory ? "Workspace" : "Folder access", systemImage: "folder")
                .font(.subheadline.weight(.semibold))
            Text(request.path)
                .font(.subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("folder-request-path-" + request.id)
            Text(status)
                .font(.footnote)
                .foregroundStyle(request.state == "pending" ? .primary : .secondary)
                .accessibilityIdentifier("folder-request-status-" + request.id)
            if request.state == "pending" {
                ViewThatFits(in: .horizontal) {
                    HStack { actionButtons }
                    VStack(alignment: .leading) { actionButtons }
                }
                .disabled(disabled)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var actionButtons: some View {
        Button(request.access == "write" ? "Allow read and write" : "Allow read-only") { resolve(true) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("folder-request-approve-" + request.id)
        Button("Decline") { resolve(false) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("folder-request-decline-" + request.id)
        if busy { ProgressView() }
    }
}
