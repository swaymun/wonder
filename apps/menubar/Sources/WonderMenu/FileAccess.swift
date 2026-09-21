import AppKit
import Combine

struct FileAccessBot: Decodable, Identifiable { let id: String; let name: String; let isArchived: Bool }
struct PendingFileAccess: Decodable, Identifiable { let id: String; let path: String; let access: String; let useAsWorkingDirectory: Bool; let state: String }
struct FileAccessPolicy: Codable {
    var revision: Int
    var appliedRevision: Int
    var readRoots: [String]
    var writeRoots: [String]
}
struct FileAccessSnapshot: Decodable {
    let botId: String
    let botName: String
    let workspacePath: String
    let access: FileAccessPolicy
}
private final class FileAccessTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor final class FileAccessModel: ObservableObject {
    @Published var bots: [FileAccessBot] = []
    @Published var selected = ""
    @Published var requests: [PendingFileAccess] = []
    @Published var snapshot: FileAccessSnapshot?
    @Published var busy = false
    @Published var message: String?
    private var host: String?
    private let origin: URL?
    private let capability: String?
    private let session: URLSession
    init() {
        let environment = ProcessInfo.processInfo.environment
        let candidate = URL(string: "http://" + (environment["WONDER_LISTEN_ADDR"] ?? "127.0.0.1:3777"))
        origin = candidate.flatMap { url in
            url.host == "127.0.0.1" && (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil && url.user == nil && url.password == nil ? url : nil
        }
        capability = environment["WONDER_LOOPBACK_CAPABILITY"]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: FileAccessTransport(), delegateQueue: nil)
    }
    private func request(_ path: String, body: Data? = nil, method: String = "PUT") async throws -> Data {
        guard let origin, let capability, !capability.isEmpty else { throw failure("Open settings from the installed Wonder app.") }
        var request = URLRequest(url: origin.appendingPathComponent("api/v1/" + path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(capability, forHTTPHeaderField: "x-wonder-loopback-capability")
        if let body { request.httpMethod = method; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data,response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "Wonder could not update file access."
            throw failure(String(detail.prefix(300)))
        }
        return data
    }
    private func checkHost() async throws {
        struct Status: Decodable { let hostInstallationId: String }
        let status = try JSONDecoder().decode(Status.self, from: await request("host/status"))
        guard host == nil || host == status.hostInstallationId else { throw failure("This Mac's identity changed. Reopen Wonder settings.") }
        host = status.hostInstallationId
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "WonderFileAccess", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await checkHost()
            bots = try JSONDecoder().decode([FileAccessBot].self, from: await request("bots")).filter { !$0.isArchived }
            // Only contextual requests reach the Mac helper. Existing grants are
            // managed from the Bot on a paired client, never from global Settings.
            var nextRequests: [PendingFileAccess] = []
            var nextSelected = ""
            var nextSnapshot: FileAccessSnapshot?
            for bot in bots {
                let pending = try JSONDecoder().decode([PendingFileAccess].self, from: await request("bots/\(bot.id)/file-access/requests")).filter { $0.state == "pending" }
                if !pending.isEmpty {
                    nextSelected = bot.id
                    nextSnapshot = try JSONDecoder().decode(FileAccessSnapshot.self, from: await request("bots/\(bot.id)/file-access"))
                    nextRequests = pending
                    break
                }
            }
            requests = nextRequests; selected = nextSelected; snapshot = nextSnapshot
        } catch { message = error.localizedDescription }
    }
    func existingFolderPaths() async throws -> [String] {
        try await checkHost()
        let bots = try JSONDecoder().decode([FileAccessBot].self, from: await request("bots"))
        var paths = Set<String>()
        for bot in bots {
            let snapshot = try JSONDecoder().decode(FileAccessSnapshot.self, from: await request("bots/\(bot.id)/file-access"))
            paths.formUnion(snapshot.access.readRoots + snapshot.access.writeRoots + [snapshot.workspacePath])
        }
        return paths.sorted()
    }
    func decide(_ item: PendingFileAccess, accepted: Bool) async {
        guard !busy, !selected.isEmpty else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await checkHost()
            let body = try JSONSerialization.data(withJSONObject: ["accepted": accepted])
            _ = try await request("bots/\(selected)/file-access/requests/\(item.id)", body: body, method: "POST")
            requests.removeAll { $0.id == item.id }
        } catch { message = error.localizedDescription }
    }
    func review(_ item: PendingFileAccess) {
        guard !busy, snapshot?.botId == selected else { return }
        busy = true
        let botID = selected
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: item.path)
        panel.prompt = item.access == "write" ? "Allow read and write" : "Allow read only"
        panel.message = (snapshot?.botName ?? "This Bot") + " wants access to: " + item.path
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                guard response == .OK, self.selected == botID, var access = self.snapshot?.access, let url = panel.url else { return }
                guard url.resolvingSymlinksInPath().path == item.path else {
                    self.message = "Choose the requested folder, or deny this request and choose a different folder on your device."
                    return
                }
                if item.access == "write" { access.writeRoots.append(item.path) } else { access.readRoots.append(item.path) }
                await self.save(access)
                guard self.message == nil else { return }
                await self.decide(item, accepted: true)
            }
        }
    }
    func save(_ access: FileAccessPolicy) async {
        guard !busy, !selected.isEmpty, snapshot?.botId == selected else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await checkHost()
            let body = try JSONSerialization.data(withJSONObject: ["revision":access.revision,"readRoots":access.readRoots,"writeRoots":access.writeRoots])
            snapshot = try JSONDecoder().decode(FileAccessSnapshot.self, from: await request("bots/\(selected)/file-access", body: body))
        } catch {
            message = error.localizedDescription
            // A saved policy can outlive a failed activation; retain its current revision.
            if let data = try? await request("bots/\(selected)/file-access"), let current = try? JSONDecoder().decode(FileAccessSnapshot.self, from: data) { snapshot = current }
        }
    }
}

/// User-selected macOS folders, separate from per-Bot sandbox permissions.
@MainActor final class ComputerFolders {
    struct Selection: Codable { let path: String; let bookmark: Data; var imported: Bool? }
    private let defaults: UserDefaults
    private let key = "computer.selectedFolders.v1"
    private let excludedRoots: [String]
    private var selections: [Selection] = []
    private var scopes: [String: URL] = [:]
    private var unavailable = Set<String>()
    var message: String?
    var rows: [[String: Any]] {
        selections.map { ["path": $0.path, "name": URL(fileURLWithPath: $0.path).lastPathComponent,
                          "available": !unavailable.contains($0.path), "imported": $0.imported == true] }
    }
    static let internalRoots = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wonder").path, "/tmp", "/private/tmp"]
    static func isVisible(_ path: String, excluding roots: [String] = internalRoots) -> Bool {
        let lexicalPath = path
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return !roots.contains { root in
            let lexicalRoot = root
            let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            return lexicalPath == lexicalRoot || lexicalPath.hasPrefix(lexicalRoot + "/")
                || resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/")
        }
    }
    init(defaults: UserDefaults = .standard, excludedRoots: [String] = ComputerFolders.internalRoots) {
        self.defaults = defaults
        self.excludedRoots = excludedRoots
        guard let data = defaults.data(forKey: key) else { return }
        do {
            selections = try JSONDecoder().decode([Selection].self, from: data).filter { Self.isVisible($0.path, excluding: excludedRoots) }
            defaults.set(try JSONEncoder().encode(selections), forKey: key)
            for item in selections {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: item.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    if url.startAccessingSecurityScopedResource() { scopes[item.path] = url }
                    if stale || url.path != item.path || !FileManager.default.fileExists(atPath: url.path) { unavailable.insert(item.path) }
                } else { unavailable.insert(item.path) }
            }
        } catch { message = "Saved folders could not be loaded. Add them again." }
    }
    func remember(_ url: URL, imported: Bool = false) throws {
        guard Self.isVisible(url.path, excluding: excludedRoots) else {
            throw NSError(domain: "WonderFolders", code: 1, userInfo: [NSLocalizedDescriptionKey: "Temporary folders and Wonder’s internal folders are not included in this list."])
        }
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var next = selections.filter { $0.path != url.path }
        next.append(Selection(path: url.path, bookmark: bookmark, imported: imported))
        next.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: key)
        selections = next
        scopes.removeValue(forKey: url.path)?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { scopes[url.path] = url }
        unavailable.remove(url.path)
        guard !imported else { return }
        // Exercise the selected directory now, while the owner is at setup.
        do { _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
        catch { unavailable.insert(url.path); message = "macOS could not read \(url.lastPathComponent). Review Files and Folders in System Settings." }
    }
    func importExisting(_ paths: [String]) {
        let seenKey = "computer.importedFolders.v1"
        var seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
        for path in Set(paths).sorted() where !seen.contains(path) && Self.isVisible(path, excluding: excludedRoots) {
            if selections.contains(where: { $0.path == path }) { seen.insert(path); continue }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { continue }
            do {
                try remember(URL(fileURLWithPath: path, isDirectory: true), imported: true)
                seen.insert(path)
            } catch { message = "Some existing folders could not be restored. Add them with +." }
        }
        defaults.set(seen.sorted(), forKey: seenKey)
    }
    func remove(_ path: String) {
        do {
            let next = selections.filter { $0.path != path }
            defaults.set(try JSONEncoder().encode(next), forKey: key)
            selections = next
            scopes.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
            unavailable.remove(path)
            message = nil
        } catch { message = "The folder could not be removed. Try again." }
    }
    func openPrivacy(fullDisk: Bool, setup: Bool = false) {
        let anchor = fullDisk ? "Privacy_AllFiles" : "Privacy_FilesAndFolders"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"), PrivacySettings.open(url, revealApplication: fullDisk && setup) else {
            message = "Open System Settings → Privacy & Security to manage Wonder’s access."
            return
        }
    }
}
