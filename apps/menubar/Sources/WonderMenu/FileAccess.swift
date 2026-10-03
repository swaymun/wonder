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
