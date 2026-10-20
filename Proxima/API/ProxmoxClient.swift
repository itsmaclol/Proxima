import CryptoKit
import Foundation

nonisolated enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
}

enum PVEError: LocalizedError {
    case untrustedCertificate(CertificateTrust.Presented)
    case unauthorized
    case server(message: String, fields: [String: String], status: Int)
    case http(Int)
    case invalidResponse
    case unreachable(String)
    /// macOS Local Network privacy hasn't been granted to Proxima yet.
    case localNetworkDenied

    var errorDescription: String? {
        switch self {
        case .untrustedCertificate: "The server's certificate isn't trusted yet."
        case .unauthorized: "Your session has expired. Sign in again."
        case .server(let message, let fields, _):
            fields.isEmpty ? message
                : ([message] + fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }).joined(separator: "\n")
        case .http(let code): "The server answered with HTTP \(code)."
        case .invalidResponse: "The server sent a response Proxima couldn't read."
        case .unreachable(let reason): reason
        case .localNetworkDenied:
            "macOS is blocking Proxima from your local network. Allow Proxima in System Settings → Privacy & Security → Local Network, then try again."
        }
    }

    /// True for a rejected username, password or second factor.
    var isAuthenticationFailure: Bool {
        if case .server(_, _, let status) = self { return status == 401 }
        return false
    }
}

/// Talks to one Proxmox VE server over its REST API.
///
/// Uses the `/api2/extjs` format (as the official web UI does) because error messages
/// arrive in the body there; the plain JSON format only puts them in the HTTP reason phrase,
/// which URLSession can't read.
final class ProxmoxClient {
    enum Credential {
        case ticket(ticket: String, csrf: String, issued: Date)
        case token(header: String)
    }

    enum LoginOutcome {
        case signedIn
        case needsSecondFactor(challenge: String, methods: [String])
    }

    let server: ServerProfile
    private(set) var credential: Credential?
    /// The user ID the server says we are, e.g. "root@pam" or "automation@pve!terraform".
    private(set) var userid: String
    private let trust: CertificateTrust
    private let session: URLSession
    private var renewal: Task<Void, Error>?

    init(server: ServerProfile) {
        self.server = server
        userid = server.usesToken ? server.tokenID : server.userid
        trust = CertificateTrust(pinnedFingerprint: server.fingerprint)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    var ticket: String? {
        if case .ticket(let ticket, _, _) = credential { return ticket }
        return nil
    }

    // MARK: Signing in

    func login(password: String) async throws -> LoginOutcome {
        let data = try await send(.post, "/access/ticket", ["username": server.userid, "password": password], signed: false).data
        return try accept(loginResponse: data)
    }

    /// `response` is "totp:123456", "recovery:abcd-efgh" or "yubico:…", as pveproxy expects.
    func completeSecondFactor(challenge: String, response: String) async throws {
        let data = try await send(.post, "/access/ticket",
                                  ["username": server.userid, "tfa-challenge": challenge, "password": response], signed: false).data
        guard case .signedIn = try accept(loginResponse: data) else { throw PVEError.invalidResponse }
    }

    /// OpenID Connect: the realm's provider page to sign in on. The provider then sends the browser to `redirect`
    /// with a code and the state.
    func openIDAuthURL(realm: String, redirect: String) async throws -> URL {
        let data = try await send(.post, "/access/openid/auth-url", ["realm": realm, "redirect-url": redirect], signed: false).data
        guard let text = data as? String, let url = URL(string: text) else { throw PVEError.invalidResponse }
        return url
    }

    /// Trades the provider's code for a ticket, like a password sign-in.
    func completeOpenID(code: String, state: String, redirect: String) async throws {
        let data = try await send(.post, "/access/openid/login", ["code": code, "state": state, "redirect-url": redirect], signed: false).data
        guard case .signedIn = try accept(loginResponse: data) else { throw PVEError.invalidResponse }
    }

    func useToken(secret: String) {
        credential = .token(header: "PVEAPIToken=\(server.tokenID)=\(secret)")
    }

    private func accept(loginResponse data: Any?) throws -> LoginOutcome {
        guard let object = data as? JSONObject, let ticket = object.text("ticket") else { throw PVEError.invalidResponse }
        if object.bool("NeedTFA") {
            return .needsSecondFactor(challenge: ticket, methods: Self.secondFactorMethods(in: ticket))
        }
        credential = .ticket(ticket: ticket, csrf: object.string("CSRFPreventionToken") ?? "", issued: .now)
        userid = object.text("username") ?? server.userid
        return .signedIn
    }

    /// The challenge ticket embeds the allowed methods: `PVE:!tfa!{"totp":true,"recovery":"available"}:…`
    static func secondFactorMethods(in ticket: String) -> [String] {
        guard let start = ticket.range(of: "!tfa!")?.upperBound else { return ["totp"] }
        let rest = ticket[start...]
        let encoded = rest.firstIndex(of: ":").map { String(rest[..<$0]) } ?? String(rest)
        guard let json = encoded.removingPercentEncoding?.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: json)) as? JSONObject else { return ["totp"] }
        var methods: [String] = []
        if jsonBool(object["totp"]) { methods.append("totp") }
        if jsonBool(object["yubico"]) { methods.append("yubico") }
        if let recovery = object.string("recovery"), !["", "0", "unavailable"].contains(recovery) { methods.append("recovery") }
        // Security keys arrive as a challenge object; only a browser can answer it for a self-hosted server.
        for key in ["webauthn", "u2f"] where object[key] != nil && !(object[key] is NSNull) { methods.append(key) }
        return methods.isEmpty ? ["totp"] : methods
    }

    // MARK: Requests

    @discardableResult
    func get(_ path: String, _ query: [String: String] = [:]) async throws -> Any? {
        try await call(.get, path, query).data
    }

    @discardableResult
    func post(_ path: String, _ params: [String: String] = [:]) async throws -> Any? {
        try await call(.post, path, params).data
    }

    @discardableResult
    func put(_ path: String, _ params: [String: String] = [:]) async throws -> Any? {
        try await call(.put, path, params).data
    }

    @discardableResult
    func delete(_ path: String, _ params: [String: String] = [:]) async throws -> Any? {
        try await call(.delete, path, params).data
    }

    func list(_ path: String, _ query: [String: String] = [:]) async throws -> [JSONObject] {
        try await get(path, query) as? [JSONObject] ?? []
    }

    func object(_ path: String, _ query: [String: String] = [:]) async throws -> JSONObject {
        try await get(path, query) as? JSONObject ?? [:]
    }

    func call(_ method: HTTPMethod, _ path: String, _ params: [String: String] = [:]) async throws -> (data: Any?, total: Int?) {
        try await renewTicketIfNeeded()
        return try await send(method, path, params, signed: true)
    }

    private func send(_ method: HTTPMethod, _ path: String, _ params: [String: String], signed: Bool) async throws -> (data: Any?, total: Int?) {
        let encoded = Self.formEncode(params)
        var url = server.baseURL.absoluteString + "/api2/extjs" + path
        if (method == .get || method == .delete), !encoded.isEmpty { url += "?" + encoded }
        guard let requestURL = URL(string: url) else { throw PVEError.invalidResponse }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method.rawValue
        if method == .post || method == .put {
            request.httpBody = Data(encoded.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        if signed { sign(&request, method) }
        let (body, response) = try await perform(request)
        return try decode(body, response)
    }

    private func sign(_ request: inout URLRequest, _ method: HTTPMethod) {
        switch credential {
        case .ticket(let ticket, let csrf, _):
            request.setValue("PVEAuthCookie=\(ticket)", forHTTPHeaderField: "Cookie")
            if method != .get { request.setValue(csrf, forHTTPHeaderField: "CSRFPreventionToken") }
        case .token(let header):
            request.setValue(header, forHTTPHeaderField: "Authorization")
        case nil:
            break
        }
    }

    private func perform(_ request: URLRequest, delegate: URLSessionTaskDelegate? = nil, uploading file: URL? = nil) async throws -> (Data, URLResponse) {
        do {
            if let file { return try await session.upload(for: request, fromFile: file, delegate: delegate) }
            return try await session.data(for: request)
        } catch {
            try transportFailure(error)
        }
    }

    private func transportFailure(_ error: Error) throws -> Never {
        try Task.checkCancellation()
        if let presented = trust.lastRejected, (error as? URLError)?.code == .cancelled || (error as? URLError)?.code == .serverCertificateUntrusted {
            throw PVEError.untrustedCertificate(presented)
        }
        if Self.isLocalNetworkDenied(error) { throw PVEError.localNetworkDenied }
        let reason = (error as? URLError).map(Self.describe) ?? error.localizedDescription
        throw PVEError.unreachable(reason)
    }

    private func decode(_ body: Data, _ response: URLResponse) throws -> (data: Any?, total: Int?) {
        guard let http = response as? HTTPURLResponse else { throw PVEError.invalidResponse }
        if http.statusCode == 401 { throw PVEError.unauthorized }
        guard http.statusCode == 200 else { throw PVEError.http(http.statusCode) }
        guard let json = (try? JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)) as? JSONObject else {
            throw PVEError.invalidResponse
        }
        if json["success"] != nil, !json.bool("success") {
            let message = (json.string("message") ?? "Request failed").trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = (json.object("errors") ?? [:]).reduce(into: [String: String]()) { result, item in
                result[item.key] = (item.value as? String ?? "\(item.value)").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            throw PVEError.server(message: message, fields: fields, status: json.int("status") ?? 500)
        }
        let data = json["data"]
        return (data is NSNull ? nil : data, json.int("total"))
    }

    /// Tickets are valid for two hours; swap for a fresh one after an hour.
    private func renewTicketIfNeeded() async throws {
        guard case .ticket(let ticket, _, let issued) = credential, Date.now.timeIntervalSince(issued) > 3600 else { return }
        if let renewal { return try await renewal.value }
        let task = Task {
            let data = try await send(.post, "/access/ticket", ["username": userid, "password": ticket], signed: false).data
            _ = try accept(loginResponse: data)
        }
        renewal = task
        defer { renewal = nil }
        try await task.value
    }

    // MARK: Downloads

    /// Streams a raw file (not JSON), such as a file restored from a backup, to a temporary folder.
    /// The file keeps the name the server suggests, else `name`.
    func download(_ path: String, _ query: [String: String] = [:], name fallback: String? = nil) async throws -> URL {
        try await renewTicketIfNeeded()
        let encoded = Self.formEncode(query)
        guard let url = URL(string: server.baseURL.absoluteString + "/api2/json" + path + (encoded.isEmpty ? "" : "?" + encoded)) else { throw PVEError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        sign(&request, .get)
        let file: URL, response: URLResponse
        do {
            (file, response) = try await session.download(for: request)
        } catch {
            try transportFailure(error)
        }
        guard let http = response as? HTTPURLResponse else { throw PVEError.invalidResponse }
        if http.statusCode == 401 { throw PVEError.unauthorized }
        guard http.statusCode == 200 else {
            // Errors come back as {"message": …} in the body.
            let message = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? JSONObject)?.text("message")
            throw message.map { PVEError.server(message: $0.trimmingCharacters(in: .whitespacesAndNewlines), fields: [:], status: http.statusCode) } ?? PVEError.http(http.statusCode)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("proxima-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suggested = http.value(forHTTPHeaderField: "Content-Disposition") == nil ? nil : response.suggestedFilename
        let name = (suggested ?? fallback ?? "download").replacingOccurrences(of: "/", with: "-")
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    // MARK: Uploads

    /// Streams a file as multipart/form-data, reporting progress from 0 to 1.
    func upload(_ path: String, fields: [String: String], file: URL, fileField: String = "filename",
                progress: @escaping @MainActor (Double) -> Void) async throws -> Any? {
        try await renewTicketIfNeeded()
        let boundary = "ProximaBoundary\(UUID().uuidString)"
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("proxima-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        // Copying and hashing a multi-gigabyte ISO takes a while; keep it off the main thread.
        try await Task.detached(priority: .userInitiated) {
            try Self.writeMultipart(to: staged, boundary: boundary, fields: fields, fileField: fileField, file: file)
        }.value

        guard let url = URL(string: server.baseURL.absoluteString + "/api2/extjs" + path) else { throw PVEError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        sign(&request, .post)
        let reporter = UploadProgress { fraction in Task { @MainActor in progress(fraction) } }
        let (body, response) = try await perform(request, delegate: reporter, uploading: staged)
        return try decode(body, response).data
    }

    private nonisolated static func writeMultipart(to url: URL, boundary: String, fields: [String: String], fileField: String, file: URL) throws {
        // Proxmox checks the upload against this checksum, so a damaged transfer fails instead of leaving a corrupt file behind.
        var fields = fields
        fields["checksum"] = try sha256(of: file)
        fields["checksum-algorithm"] = "sha256"
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty { out.write(chunk) }
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        var hasher = SHA256()
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Helpers

    /// Items of an array parameter are joined with NUL by the caller and sent as repeated keys, which is how Proxmox reads arrays.
    static func formEncode(_ params: [String: String]) -> String {
        params.sorted { $0.key < $1.key }
            .flatMap { key, value in value.split(separator: "\0", omittingEmptySubsequences: false).map { (key, String($0)) } }
            .map { "\($0.0.addingPercentEncoding(withAllowedCharacters: .urlUnreserved) ?? $0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .urlUnreserved) ?? $0.1)" }
            .joined(separator: "&")
    }

    /// Local Network privacy shows up as "offline" with an unsatisfied path naming the reason.
    nonisolated static func isLocalNetworkDenied(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if let path = error.userInfo["_NSURLErrorNWPathKey"], "\(path)".contains("Local network prohibited") { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed: "Can't find that server. Check the address."
        case .cannotConnectToHost: "The server refused the connection. Is Proxmox running on that port?"
        case .timedOut: "The server didn't answer in time."
        case .notConnectedToInternet: "This Mac isn't connected to a network."
        case .networkConnectionLost: "The connection dropped. Try again."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            "A secure connection to the server couldn't be made."
        default: error.localizedDescription
        }
    }
}

/// Forwards upload progress from URLSession's delegate queue.
nonisolated final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
