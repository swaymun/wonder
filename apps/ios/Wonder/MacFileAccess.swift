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

enum FileAccessChoice: String, Identifiable {
    case read, write, workingDirectory
    var id: String { rawValue }
    var title: String {
        switch self { case .read: "Choose read location"; case .write: "Allow read and write"; case .workingDirectory: "Choose Workspace" }
    }
    func apply(path: String, isDirectory: Bool, to selection: inout BotFileSelection) {
        if self == .workingDirectory {
            selection.workingDirectory = path
            if !selection.directoryRoots.contains(path) { selection.directoryRoots.append(path); selection.directoryRoots.sort() }
        } else { selection.select(path: path, isDirectory: isDirectory, writable: self == .write) }
    }
}

// The enclosing form owns presentation; Form sections can be recycled while scrolling.
struct BotFileAccessFields: View {
    @Binding var selection: BotFileSelection
    let workspacePath: String?
    let permissionMode: BotPermissionMode?
    @Binding var adding: FileAccessChoice?
    var body: some View {
        if permissionMode == .readOnly || permissionMode == .fullAccess {
            if !selection.readRoots.isEmpty || !selection.writeRoots.isEmpty {
                Section {
                    ForEach(selection.readRoots + selection.writeRoots, id: \.self) { path in
                        Label(path, systemImage: selection.directoryRoots.contains(path) ? "folder" : "doc")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Saved locations") } footer: {
                    Text(permissionMode == .readOnly ? "These selections are kept for other modes. Read-only asks before editing these locations." : "These selections are kept for other modes. Full access is not restricted to these locations.")
                }
            }
        } else {
            if permissionMode == nil || !selection.readRoots.isEmpty {
            Section {
                ForEach(selection.readRoots, id: \.self) { path in location(path) }
                if permissionMode == nil { Button("Add file or folder", systemImage: "plus") { adding = .read }.disabled(selection.readRoots.count + selection.writeRoots.count >= 32) }
            } header: { Text(permissionMode == .workspace ? "Saved read locations" : "Read only") } footer: {
                if permissionMode == .workspace { Text("Workspace mode already reads across your Mac. These selections are retained for this Bot.") }
            }
            }
            Section {
                ForEach(selection.writeRoots, id: \.self) { path in location(path) }
                Button("Add file or folder", systemImage: "plus") { adding = .write }.disabled(selection.readRoots.count + selection.writeRoots.count >= 32)
                if selection.readRoots.count + selection.writeRoots.count >= 32 { Text("You can choose up to 32 locations. Remove one to add another.").font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Read and write") }
        }
        Section {
            LabeledContent("Workspace") {
                if let path = selection.workingDirectory ?? workspacePath {
                    Text(path).font(.footnote).textSelection(.enabled)
                } else {
                    Text("Created when the Bot is saved").foregroundStyle(.secondary)
                }
            }
            if permissionMode != nil { Button("Choose Workspace", systemImage: "folder") { adding = .workingDirectory } }
        } footer: {
            if permissionMode == .workspace { Text("Where the Bot starts work and can edit files.") }
            else if permissionMode != nil { Text("Where the Bot starts work.") }
            else if selection.directoryRoots.isEmpty { Text("Choose a folder above to use it as the Workspace.") }
        }
    }

    private func location(_ path: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selection.directoryRoots.contains(path) ? "folder" : "doc")
                .foregroundStyle(.secondary).accessibilityHidden(true)
            Text(path).font(.footnote).textSelection(.enabled)
            Spacer(minLength: 0)
            Menu {
                if selection.readRoots.contains(path) { Button("Allow read and write") { selection.select(path: path, isDirectory: selection.directoryRoots.contains(path), writable: true) } }
                else { Button("Make read only") { selection.select(path: path, isDirectory: selection.directoryRoots.contains(path), writable: false) } }
                Button("Remove access", role: .destructive) { selection.remove(path: path) }
            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Access for \(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }
}

struct BotFileAccessView: View {
    let model: ConnectionModel
    let bot: ManagedBot
    var workspaceSaved: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var permissionMode: BotPermissionMode?
    @State private var selection = BotFileSelection()
    @State private var adding: FileAccessChoice?
    @State private var revision: Int?
    @State private var appliedRevision: Int?
    @State private var originalWorkingDirectory: String?
    @State private var busy = false
    @State private var saving = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var savedNotice: String?
    private var key: String { "file-access." + bot.id }
    private var path: String { "/api/v1/bots/" + ConnectionModel.escape(bot.id) }
    private var selectionBinding: Binding<BotFileSelection> {
        Binding(get: { selection }, set: { selection = $0; savedNotice = nil; persist() })
    }
    var body: some View {
        Form {
            if loaded {
                Section { LabeledContent("Permissions", value: permissionMode?.title ?? "Workspace") } footer: {
                    Text(permissionMode?.scopeDescription ?? BotPermissionMode.selectedWorkspaceDescription)
                }
                BotFileAccessFields(selection: selectionBinding, workspacePath: bot.workspacePath, permissionMode: permissionMode, adding: $adding)
            }
            if busy { ProgressView(saving ? "Saving file access…" : "Loading file access…") }
            if let failure { Section { FailureDetails(message: failure); Button("Reload saved access") { Task { await load(discardDraft: true) } } } }
            if let savedNotice { Text(savedNotice).foregroundStyle(.secondary) }
            if let revision, let appliedRevision, revision != appliedRevision { Text("These permissions are saved but are not active yet. Stop active work and save again.").foregroundStyle(.secondary) }
        }.disabled(busy)
        .navigationTitle("File access")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(busy || revision == nil) } }
        .task { if !loaded { await load() } }
        .sheet(item: $adding) { choice in
            MacLocationBrowser(model: model, title: choice.title, foldersOnly: choice == .workingDirectory) { path, directory in
                choice.apply(path: path, isDirectory: directory, to: &selectionBinding.wrappedValue)
            }
        }
    }
    private func persist() {
        var draft = ManagementDraft(); draft.values["_fileAccess"] = selection.encodedDraft
        if let revision { draft.values["revision"] = String(revision) }
        do { try model.managementDrafts?.save(draft, key: key) } catch { failure = "These selections could not be saved on this device." }
    }
    private func load(discardDraft: Bool = false) async {
        busy = true; failure = nil; defer { busy = false }
        do {
            let reply: BotFileAccessReply = try await model.manage(path + "/file-access")
            let currentBot: ManagedBot = try await model.manage(path)
            permissionMode = currentBot.permissionMode.flatMap(BotPermissionMode.init(rawValue:))
            appliedRevision = reply.access.appliedRevision
            originalWorkingDirectory = currentBot.workingDirectory ?? bot.workspacePath
            if !discardDraft, let draft = model.managementDrafts?.load(key), let base = draft.values["revision"].flatMap(Int.init) {
                selection = BotFileSelection.draft(draft.values["_fileAccess"]); revision = base
                if base != reply.access.revision && !selection.matches(reply.access) { failure = "File access changed on another device. Reload saved access before making new changes." }
            } else {
                selection = BotFileSelection(); selection.readRoots = reply.access.readRoots; selection.writeRoots = reply.access.writeRoots
                if let directory = currentBot.workingDirectory, directory != bot.workspacePath { selection.workingDirectory = directory; selection.directoryRoots = [directory] }
                revision = reply.access.revision
                if discardDraft { model.managementDrafts?.remove(key) }
            }
            await loadDirectoryKinds()
            loaded = true
        } catch { failure = "File access could not be loaded. Reconnect to your Mac and try again." }
    }
    private func loadDirectoryKinds() async {
        let roots = Array(Set(selection.readRoots + selection.writeRoots))
        let model = model
        var directories: [String] = []
        // Match the Mac browser's two concurrent disk workers.
        for start in stride(from: 0, to: roots.count, by: 2) {
            let batch = Array(roots[start..<min(start + 2, roots.count)])
            let found = await withTaskGroup(of: String?.self, returning: [String].self) { tasks in
                for path in batch {
                    tasks.addTask {
                        var url = URLComponents(); url.path = "/api/v1/filesystem"; url.queryItems = [URLQueryItem(name: "path", value: path)]
                        let page: MacLocationPage? = try? await model.manage(url.string!)
                        return page?.path
                    }
                }
                var result: [String] = []
                for await path in tasks { if let path { result.append(path) } }
                return result
            }
            directories += found
        }
        if let current = selection.workingDirectory { directories.append(current) }
        selection.directoryRoots = Array(Set(directories)).sorted()
    }
    private func save() async {
        guard let revision else { return }; busy = true; saving = true; failure = nil; savedNotice = nil; persist(); defer { busy = false; saving = false }
        do {
            let currentBot: ManagedBot = try await model.manage(path)
            guard currentBot.permissionMode.flatMap(BotPermissionMode.init(rawValue:)) == permissionMode else {
                failure = "This Bot’s permission mode changed. Reload saved access before making changes."
                return
            }
            var current: BotFileAccessReply = try await model.manage(path + "/file-access")
            if !selection.matches(current.access) || current.access.revision != current.access.appliedRevision {
                guard current.access.revision == revision || selection.matches(current.access) else { failure = "File access changed on another device. Reload saved access before making new changes."; return }
                struct Change: Encodable { let revision: Int; let readRoots: [String]; let writeRoots: [String] }
                struct Reply: Decodable, Sendable {}
                let _: Reply = try await model.manage(path + "/file-access", method: "PUT", body: JSONEncoder().encode(Change(revision: current.access.revision, readRoots: selection.readRoots, writeRoots: selection.writeRoots)))
                current = try await model.manage(path + "/file-access")
                guard selection.matches(current.access) else { failure = "File access changed while saving. Reload saved access to review it."; return }
            }
            self.revision = current.access.revision; appliedRevision = current.access.appliedRevision; persist()
            guard current.access.revision == current.access.appliedRevision else { failure = "File access is saved but could not be activated. Stop active work and try saving again."; return }
            let directory = selection.workingDirectory ?? bot.workspacePath
            if directory != originalWorkingDirectory {
                do {
                    let _: ManagedBot = try await model.manage(path, method: "PATCH", values: ["workingDirectory": directory])
                    originalWorkingDirectory = directory
                    workspaceSaved(directory)
                } catch {
                    failure = "File access is saved, but the Workspace could not be confirmed. Stop active work and try saving again."
                    return
                }
            }
            model.managementDrafts?.remove(key); savedNotice = "File access saved."; await model.loadChats(force: true)
        } catch {
            if case PairingFailure.response(409) = error { failure = "File access could not be changed. Stop active work, then reload saved access and try again." }
            else { failure = "Your Mac could not confirm all changes. Your selections are saved; reconnect and try again." }
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
                    disabled: busy != nil || model.accessEnded,
                    resolve: { accepted in Task { await resolve(request, accepted: accepted) } })
            }
            if let failure { FailureDetails("Folder request unavailable", message: failure) }
        }.task(id: botID) {
            guard !model.previewMode else { return }
            while !Task.isCancelled {
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
        do {
            requests = try await model.manage(endpoint)
            failure = nil
        } catch {
            if requests.isEmpty { failure = refreshFailure(error) }
            return
        }
    }
    private func refreshFailure(_ error: Error) -> String {
        if model.accessEnded { return "Reconnect this device to review or apply the saved folder request." }
        if case PairingFailure.response(let status) = error {
            switch status {
            case 404: return "This Bot is unavailable or archived. Reopen it on an updated Mac host to recover the request."
            case 409: return "This Bot is busy. The request is retained; stop current work and refresh to retry."
            default: break
            }
        }
        return "The Mac could not refresh this request. The pending decision is retained; reconnect and try again."
    }
    private func resolve(_ request: BotFolderRequest, accepted: Bool) async {
        busy = request.id; failure = nil
        defer { busy = nil }
        do {
            struct Decision: Encodable { let accepted: Bool }
            struct Empty: Decodable, Sendable {}
            let _: Empty = try await model.manage(endpoint + "/" + ConnectionModel.escape(request.id), method: "POST", body: JSONEncoder().encode(Decision(accepted: accepted)))
            await refresh()
        } catch { failure = refreshFailure(error) }
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
