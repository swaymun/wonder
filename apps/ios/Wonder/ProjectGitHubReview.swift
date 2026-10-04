import SwiftUI
import WonderPairing
import CryptoKit

struct ProjectGitHubEntry: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject private var projects: ProjectLibrary
    let chat: ChatSummary
    let root: WorkspaceRoot?
    let open: () -> Void
    init(model: ConnectionModel, chat: ChatSummary, root: WorkspaceRoot?, open: @escaping () -> Void) {
        self.model = model; projects = model.projects; self.chat = chat; self.root = root; self.open = open
    }
    var body: some View {
        if projects.supportsGitHubReview, let rootId = root?.projectRootId, model.gitHubReviewProject(chat, rootId: rootId) != nil {
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                open()
            } label: { Image(systemName: "arrow.triangle.pull").font(.system(size: 20)).frame(width: 44, height: 44) }
                .accessibilityLabel("Pull requests").accessibilityIdentifier("workspace-github-review")
        }
    }
}

@MainActor final class ProjectGitHubReviewOwner: ObservableObject {
    @Published private(set) var status: GitHubReviewStatus?
    @Published private(set) var preparation: GitHubReviewPreparation?
    @Published private(set) var snapshot: GitHubPullRequestSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    private weak var model: ConnectionModel?
    let projectId: String
    let rootId: String
    private var visible = false
    private var foreground = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    init(model: ConnectionModel, projectId: String, rootId: String) {
        self.model = model; self.projectId = projectId; self.rootId = rootId
    }
    var scope: GitHubReviewScope? {
        guard let model, let project = model.projects.projects.first(where: { $0.id == projectId }) else { return nil }
        return try? GitHubReviewScope(project: project, folderId: rootId,
                                     hostVersion: model.projects.supportsGitHubReview ? 1 : nil)
    }
    private func current(_ id: UUID, _ client: GitHubReviewClient) -> Bool {
        guard visible, foreground, generation == id, !Task.isCancelled, let model, let scope else { return false }
        return model.matchesGitHubReviewClient(client, scope: scope)
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        status = nil; preparation = nil; snapshot = nil; busy = false; failure = nil
    }
    func appear(foreground: Bool) {
        visible = true; self.foreground = foreground
        contextChanged()
    }
    func disappear() { visible = false; stop() }
    func sceneChanged(foreground: Bool) { self.foreground = foreground; contextChanged() }
    func contextChanged() { stop(); if visible && foreground { reload() } }
    func cancel() { stop(); failure = "Loading cancelled. Reload the connection to continue." }
    func abandonPreparation() { preparation = nil }
    private func run(_ operation: @escaping @MainActor (ProjectGitHubReviewOwner, GitHubReviewClient, UUID) async throws -> Void) {
        guard visible, foreground else { return }
        task?.cancel(); let id = UUID(); generation = id; failure = nil; busy = true
        guard let model, let scope else { stop(); failure = "This Project folder changed. Return to Files and reopen it."; return }
        let client: GitHubReviewClient
        do { client = try model.makeGitHubReviewClient(scope) }
        catch { busy = false; failure = error.localizedDescription; return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == id { busy = false; task = nil } }
            do {
                guard current(id, client) else { return }
                try await operation(self, client, id)
            } catch is CancellationError { }
            catch {
                guard current(id, client) else { return }
                status = nil; preparation = nil; snapshot = nil
                failure = error.localizedDescription
            }
        }
    }
    func reload() {
        snapshot = nil; preparation = nil; status = nil
        run { owner, client, id in
            let status = try await client.status()
            guard owner.current(id, client) else { return }
            owner.status = status
        }
    }
    func prepare() {
        preparation = nil; snapshot = nil
        run { owner, client, id in
            let prepared = try await client.prepare()
            guard owner.current(id, client) else { return }
            owner.preparation = prepared
        }
    }
    func authorize() {
        guard let prepared = preparation else { return }
        preparation = nil
        run { owner, client, id in
            try await client.authorize(prepared)
            let status = try await client.status()
            guard owner.current(id, client) else { return }
            owner.status = status
        }
    }
    func disconnect() {
        guard let status else { return }
        snapshot = nil; preparation = nil
        run { owner, client, id in
            try await client.disconnect(status)
            let status = try await client.status()
            guard owner.current(id, client) else { return }
            owner.status = status
        }
    }
    func load(_ number: UInt64) {
        guard let status else { return }
        snapshot = nil
        run { owner, client, id in
            let snapshot = try await client.snapshot(number: number, connected: status)
            guard owner.current(id, client) else { return }
            owner.snapshot = snapshot
        }
    }
}

struct ProjectGitHubFolderReview: View {
    let model: ConnectionModel
    let projectId: String
    let rootId: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ProjectGitHubReviewPanel(model: model, projectId: projectId, rootId: rootId, backTitle: "Project") { dismiss() }
            .toolbar(.hidden, for: .navigationBar)
    }
}

struct ProjectGitHubReviewPanel: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject private var projects: ProjectLibrary
    @StateObject private var owner: ProjectGitHubReviewOwner
    @Environment(\.scenePhase) private var scenePhase
    @State private var number = ""
    @State private var selectedPath: String?
    @FocusState private var numberFocused: Bool
    let backTitle: String
    let close: () -> Void
    init(model: ConnectionModel, projectId: String, rootId: String, backTitle: String = "Files", close: @escaping () -> Void) {
        self.model = model; projects = model.projects
        _owner = StateObject(wrappedValue: ProjectGitHubReviewOwner(model: model, projectId: projectId, rootId: rootId))
        self.backTitle = backTitle; self.close = close
    }
    private var selected: GitHubReviewFile? { owner.snapshot?.files.first(where: { $0.path == selectedPath }) }
    // Session bytes remain private; hashing only supplies a change identity.
    private var pairingFence: String {
        guard let saved = model.connection else { return model.previewMode ? "preview" : "unpaired" }
        return SHA256.hash(data: Data([saved.origin, saved.credential.hostInstallationId, saved.credential.deviceId,
            saved.credential.sessionToken, saved.credential.csrfToken, String(saved.credential.expiresAtMs ?? 0), String(model.accessEnded), String(saved.requiresPairing)].joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var folderName: String {
        projects.projects.first(where: { $0.id == owner.projectId })?.folders.first(where: { $0.id == owner.rootId })?.name ?? "Project folder"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { if selected != nil { selectedPath = nil } else { close() } } label: {
                    Label(selected == nil ? backTitle : "Pull request", systemImage: "chevron.left")
                }.frame(minHeight: 44).accessibilityIdentifier("github-review-back")
                Spacer()
                Text(selected?.path ?? "Pull requests").font(.headline).lineLimit(1).truncationMode(.middle)
                if owner.busy { Button("Cancel", action: owner.cancel).frame(minHeight: 44) }
                else { Button(action: owner.reload) { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                    .accessibilityLabel("Reload GitHub connection").accessibilityIdentifier("github-review-refresh") }
            }.padding(.horizontal, 16)
            if let selected, let snapshot = owner.snapshot {
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(snapshot.identity.repository + " · #\(snapshot.identity.number)").font(.subheadline)
                            Text(selected.status.rawValue.capitalized + " · +\(selected.additions) −\(selected.deletions)").font(.caption).foregroundStyle(.secondary)
                            if let previous = selected.previousPath { Text("From " + previous).font(.caption).textSelection(.enabled) }
                            if let patch = selected.patch, selected.patchState == .suppliedCountsMatch {
                                GitHubPatchText(text: patch)
                                    .frame(height: max(240, viewport.size.height))
                                    .id(snapshot.identity.base + ":" + snapshot.identity.head + ":" + selected.path + ":" + selected.sha)
                            } else {
                                Text(patchExplanation(selected.patchState)).frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("github-patch-unavailable")
                                githubLink(snapshot)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }.accessibilityIdentifier("github-review-detail-content")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(model.macName + " · " + folderName).font(.subheadline).foregroundStyle(.secondary)
                        if owner.busy { ProgressView("Loading GitHub review…").accessibilityIdentifier("github-review-loading") }
                        if let failure = owner.failure {
                            Text(failure).foregroundStyle(.primary).accessibilityIdentifier("github-review-error")
                            Button("Reload connection", action: owner.reload).frame(minHeight: 44)
                        }
                        if let prepared = owner.preparation {
                            Text(prepared.identity.repository).font(.headline)
                            Text("Signed in as " + prepared.identity.accountLogin)
                            Text("Allow Wonder to read pull requests in this repository using GitHub on your Mac.")
                            Button("Allow read access", action: owner.authorize).buttonStyle(.borderedProminent).frame(minHeight: 44)
                                .accessibilityIdentifier("github-review-authorize")
                            Button("Cancel", action: owner.abandonPreparation).frame(minHeight: 44)
                                .accessibilityIdentifier("github-review-preparation-cancel")
                        } else if let status = owner.status {
                            if status.connected {
                                Text(status.repository ?? "Repository").font(.headline)
                                HStack {
                                    TextField("Pull request number", text: $number).keyboardType(.numbersAndPunctuation)
                                        .submitLabel(.go).onSubmit(loadNumber)
                                        .textFieldStyle(.roundedBorder).focused($numberFocused).accessibilityIdentifier("github-review-number")
                                    Button("Load", action: loadNumber)
                                        .frame(minHeight: 44).disabled(UInt64(number).map { $0 > 0 } != true || owner.busy)
                                        .accessibilityIdentifier("github-review-load")
                                }
                                if let snapshot = owner.snapshot {
                                    Text(snapshot.title).font(.headline).accessibilityIdentifier("github-review-title")
                                    Text("\(snapshot.state.capitalized) · \(snapshot.files.count) changed files").font(.subheadline)
                                    Text("Base \(snapshot.identity.base.prefix(7)) · Head \(snapshot.identity.head.prefix(7)) · Fetched \(snapshot.fetchedAt)")
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    githubLink(snapshot)
                                    LazyVStack(spacing: 0) {
                                        ForEach(snapshot.files) { file in
                                            Button { selectedPath = file.path } label: {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(file.path).lineLimit(2).truncationMode(.middle)
                                                    Text("\(file.status.rawValue.capitalized) · +\(file.additions) −\(file.deletions)").font(.caption).foregroundStyle(.secondary)
                                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 6)
                                            }.buttonStyle(.plain).accessibilityIdentifier("github-review-file:" + file.path)
                                        }
                                    }
                                }
                                Button("Disconnect GitHub", role: .destructive, action: owner.disconnect).frame(minHeight: 44)
                                    .disabled(owner.busy).accessibilityIdentifier("github-review-disconnect")
                            } else {
                                Text("Connect this folder’s GitHub repository to review its pull requests.")
                                Button("Connect GitHub", action: owner.prepare).buttonStyle(.borderedProminent).frame(minHeight: 44)
                                    .disabled(owner.busy).accessibilityIdentifier("github-review-connect")
                            }
                        }
                    }.padding(16)
                }.accessibilityIdentifier("github-review-content")
            }
        }
        .task { owner.appear(foreground: scenePhase == .active) }
        .onDisappear { owner.disappear() }
        .onChange(of: scenePhase) { _, phase in
            selectedPath = nil
            owner.sceneChanged(foreground: phase == .active)
        }
        .onChange(of: pairingFence) { _, _ in selectedPath = nil; owner.contextChanged() }
        .onChange(of: owner.scope) { _, _ in selectedPath = nil; owner.contextChanged() }
    }
    private func patchExplanation(_ state: GitHubPatchState) -> String {
        switch state {
        case .empty: "This file has no textual changes."
        case .unavailable: "GitHub did not supply a text patch for this file."
        case .partial: "GitHub supplied an incomplete text patch. Open the full change on GitHub."
        case .oversized: "This text patch exceeds the preview size limit. Open it on GitHub."
        case .suppliedCountsMatch: "This text patch is unavailable. Reload the review."
        }
    }
    private func loadNumber() {
        guard let value = UInt64(number), value > 0, !owner.busy else { return }
        numberFocused = false; selectedPath = nil; owner.load(value)
    }
    private func githubLink(_ snapshot: GitHubPullRequestSnapshot) -> some View {
        Link("Open on GitHub", destination: URL(string: "https://github.com/\(snapshot.identity.repository)/pull/\(snapshot.identity.number)")!)
            .frame(minHeight: 44).accessibilityIdentifier("github-review-open-web")
    }
}

/// The immutable source is set once per file/revision. TextKit keeps scrolling
/// and selection in a bounded native viewport, with no per-line SwiftUI views.
private struct GitHubPatchText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = true
        view.backgroundColor = .clear; view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        view.adjustsFontForContentSizeCategory = true; view.text = text
        view.accessibilityIdentifier = "github-patch-text"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {}
}

#if WONDER_DIAGNOSTICS
/// Offline-only UI fixture: no real GitHub calls, grants, messages or model work.
private final class DiagnosticGitHubReviewProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var connected = false
    private nonisolated(unsafe) static var revision = 0
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "native-github-preview.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let parts = request.url!.path.split(separator: "/").map(String.init)
        guard parts.count >= 6 else { reply(404); return }
        let project = parts[3], root = parts[5]
        let state = Self.lock.withLock { () -> (Bool, Int) in
            if request.httpMethod == "PUT" { Self.connected = true; Self.revision += 1 }
            if request.httpMethod == "DELETE" { Self.connected = false; Self.revision += 1 }
            return (Self.connected, Self.revision)
        }
        if request.httpMethod == "PUT" || request.httpMethod == "DELETE" { reply(204); return }
        let scope: [String: Any] = ["hostInstallationId": "github-preview-host", "projectId": project, "rootId": root,
                                  "rootsRevision": 1, "authorizationRevision": state.1]
        if parts.last == "prepare" {
            reply(200, scope.merging(["identity": ["accountId": 10, "accountLogin": "preview-owner", "repositoryId": 20,
                                                   "repository": "preview-owner/preview-project"]]) { _, new in new }); return
        }
        if parts.count == 8, parts[6] == "pulls" {
            guard state.0 else { reply(403); return }
            let sha = String(repeating: "a", count: 40)
            let files: [[String: Any]] = [
                ["path": "Sources/Conversation.swift", "previousPath": "Sources/Chat.swift", "sha": sha, "status": "renamed",
                 "additions": 1, "deletions": 1, "patchState": "suppliedCountsMatch", "patch": "@@ -1 +1 @@\n-let title = \"Chat\"\n+let title = \"Conversation\"\n"],
                ["path": "Assets/diagram.png", "previousPath": NSNull(), "sha": sha, "status": "modified", "additions": 0,
                 "deletions": 0, "patchState": "unavailable", "patch": NSNull()]
            ]
            let snapshot: [String: Any] = ["projectId": project, "rootId": root, "rootsRevision": 1, "accountId": 10,
                "identity": ["apiHost": "api.github.com", "repositoryId": 20, "repository": "preview-owner/preview-project",
                "headRepositoryId": 21, "headRepository": "preview-contributor/fork", "number": UInt64(parts[7]) ?? 42,
                "base": sha, "head": String(repeating: "b", count: 40)], "mergeBase": sha, "title": "Make conversation titles clearer",
                "state": "open", "fetchedAt": "2026-10-04T00:00:00Z", "enumerationComplete": true, "files": files]
            reply(200, ["hostInstallationId": "github-preview-host", "authorizationRevision": state.1, "snapshot": snapshot]); return
        }
        reply(200, scope.merging(["connected": state.0, "repository": state.0 ? "preview-owner/preview-project" : NSNull(),
                                  "repositoryId": state.0 ? 20 : NSNull(), "accountId": state.0 ? 10 : NSNull()]) { _, new in new })
    }
    private func reply(_ status: Int, _ object: [String: Any]? = nil) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: object.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}
enum DiagnosticGitHubReview {
    static let connection = try! JSONDecoder().decode(SavedConnection.self, from: Data(#"{"origin":"https://native-github-preview.invalid","credential":{"sessionToken":"synthetic","deviceId":"github-preview-phone","csrfToken":"synthetic-csrf","hostInstallationId":"github-preview-host","expiresAtMs":null}}"#.utf8))
    static func client(_ scope: GitHubReviewScope) throws -> GitHubReviewClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DiagnosticGitHubReviewProtocol.self]
        let signer = SigningIdentity(read: { Data(repeating: 7, count: 32) }, save: { _ in throw SigningIdentityFailure.invalidated },
            restore: { bytes in
                let key = try P256.Signing.PrivateKey(rawRepresentation: bytes)
                return EnrollmentSigningIdentity(publicKey: key.publicKey, representation: bytes, sign: { try key.signature(for: $0) })
            }, create: { throw SigningIdentityFailure.invalidated })
        return try GitHubReviewClient(api: PairingAPI(configuration: configuration), connection: connection, scope: scope, signer: signer)
    }
}
#endif
