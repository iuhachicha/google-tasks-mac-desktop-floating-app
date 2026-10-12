import Foundation
import AppKit
import Combine
import CryptoKit
import Network
import Security

// Google Desktop OAuth: system browser + PKCE + an ephemeral IPv4 loopback listener.
// No credentials or token responses are logged or written outside the Keychain.
@MainActor
final class GoogleOAuth: ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var isSignedIn = false
    @Published private(set) var isAuthorizing = false
    @Published private(set) var hasWriteAccess = false
    var configuredClientID: String? { client?.clientID }

    private var client: GoogleDesktopClient?
    private var tokens: GoogleOAuthTokens?
    private var startupError: Error?
    private var generation = UUID()
    private var authorizationTask: Task<GoogleOAuthTokens, Error>?
    private var authorizationID: UUID?
    private var receiver: GoogleOAuthLoopback?
    private var refreshTask: (id: UUID, task: Task<GoogleOAuthTokens, Error>)?

    init() {
        do {
            if let data = try GoogleOAuthKeychain.read(account: "desktop-client") {
                let stored = try JSONDecoder().decode(GoogleDesktopClient.self, from: data)
                try stored.validate()
                client = stored
                isConfigured = true
                if let saved = try GoogleOAuthKeychain.read(account: "tokens") {
                    let restored = try JSONDecoder().decode(GoogleOAuthTokens.self, from: saved)
                    if restored.clientID == stored.clientID && !restored.refreshToken.isEmpty && restored.hasReadAccess {
                        tokens = restored
                        isSignedIn = true
                        hasWriteAccess = restored.hasWriteAccess
                    }
                }
            }
        } catch {
            startupError = GoogleOAuthError.keychainRead
        }
    }

    func importClient(from url: URL) throws {
        guard url.isFileURL else { throw GoogleOAuthError.invalidConfiguration }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let configuration: GoogleDesktopClient
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 && size <= 65536 else { throw GoogleOAuthError.invalidConfiguration }
            configuration = try GoogleDesktopClient.importJSON(Data(contentsOf: url))
        } catch let error as GoogleOAuthError { throw error }
        catch { throw GoogleOAuthError.configurationRead }

        cancelSignIn()
        refreshTask?.task.cancel()
        refreshTask = nil
        generation = UUID()
        if client != configuration {
            try GoogleOAuthKeychain.remove(account: "tokens")
            tokens = nil
            isSignedIn = false
            hasWriteAccess = false
        }
        try GoogleOAuthKeychain.save(try JSONEncoder().encode(configuration), account: "desktop-client")
        client = configuration
        startupError = nil
        isConfigured = true
    }

    func signIn() async throws {
        guard let client else { throw startupError ?? GoogleOAuthError.notConfigured }
        guard !isAuthorizing else { throw GoogleOAuthError.alreadyAuthorizing }
        refreshTask?.task.cancel()
        refreshTask = nil
        generation = UUID()
        let attempt = UUID()
        authorizationID = attempt
        isAuthorizing = true
        let task = Task { @MainActor [self] in try await authorize(client: client) }
        authorizationTask = task
        defer {
            if authorizationID == attempt {
                receiver?.cancel()
                receiver = nil
                authorizationTask = nil
                authorizationID = nil
                isAuthorizing = false
            }
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard authorizationID == attempt else { throw GoogleOAuthError.cancelled }
            try GoogleOAuthKeychain.save(try JSONEncoder().encode(result), account: "tokens")
            tokens = result
            startupError = nil
            isSignedIn = true
            hasWriteAccess = result.hasWriteAccess
        } catch is CancellationError { throw GoogleOAuthError.cancelled }
    }

    func cancelSignIn() {
        authorizationTask?.cancel()
        receiver?.cancel()
        receiver = nil
        authorizationTask = nil
        authorizationID = nil
        isAuthorizing = false
    }

    func accessToken() async throws -> String {
        guard !isAuthorizing else { throw GoogleOAuthError.alreadyAuthorizing }
        guard let client, let saved = tokens, saved.clientID == client.clientID else {
            throw startupError ?? GoogleOAuthError.notSignedIn
        }
        try Task.checkCancellation()
        if saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        if let pending = refreshTask { return try await pending.task.value.accessToken }
        let currentGeneration = generation
        let identifier = UUID()
        let task = Task { @MainActor [self] () throws -> GoogleOAuthTokens in
            do {
                let response = try await GoogleOAuthHTTP.token(fields: [
                    "client_id": client.clientID, "client_secret": client.clientSecret,
                    "refresh_token": saved.refreshToken, "grant_type": "refresh_token"
                ])
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw GoogleOAuthError.cancelled }
                let renewed = try response.tokens(clientID: client.clientID, previousRefreshToken: saved.refreshToken,
                                                  previousGrantedScopes: saved.grantedScopes)
                try GoogleOAuthKeychain.save(try JSONEncoder().encode(renewed), account: "tokens")
                tokens = renewed
                isSignedIn = true
                hasWriteAccess = renewed.hasWriteAccess
                return renewed
            } catch GoogleOAuthError.invalidGrant {
                guard generation == currentGeneration else { throw GoogleOAuthError.cancelled }
                tokens = nil
                isSignedIn = false
                hasWriteAccess = false
                try GoogleOAuthKeychain.remove(account: "tokens")
                throw GoogleOAuthError.signInExpired
            }
        }
        refreshTask = (identifier, task)
        defer { if refreshTask?.id == identifier { refreshTask = nil } }
        do { return try await task.value.accessToken }
        catch is CancellationError { throw GoogleOAuthError.cancelled }
    }

    func signOut() throws {
        cancelSignIn()
        generation = UUID()
        refreshTask?.task.cancel()
        refreshTask = nil
        tokens = nil
        isSignedIn = false
        hasWriteAccess = false
        try GoogleOAuthKeychain.remove(account: "tokens")
        startupError = nil
    }

    private func authorize(client: GoogleDesktopClient) async throws -> GoogleOAuthTokens {
        try Task.checkCancellation()
        let verifier = try GoogleOAuthSecurity.randomURLSafe(bytes: 32)
        let state = try GoogleOAuthSecurity.randomURLSafe(bytes: 32)
        let callback = try GoogleOAuthLoopback(expectedState: state)
        receiver = callback
        defer { callback.cancel() }
        let redirect = try await callback.start()
        try Task.checkCancellation()
        var authorization = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        authorization.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuthSecurity.tasksScope),
            URLQueryItem(name: "code_challenge", value: GoogleOAuthSecurity.challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let authorizationURL = authorization.url, NSWorkspace.shared.open(authorizationURL) else {
            throw GoogleOAuthError.browserUnavailable
        }
        let code = try await callback.authorizationCode()
        try Task.checkCancellation()
        do {
            let response = try await GoogleOAuthHTTP.token(fields: [
                "client_id": client.clientID, "client_secret": client.clientSecret,
                "code": code, "code_verifier": verifier,
                "redirect_uri": redirect.absoluteString, "grant_type": "authorization_code"
            ])
            try Task.checkCancellation()
            // An upgrade must receive an explicit write grant. Keep any previous
            // authorization until this result has passed validation and is saved.
            return try response.tokens(clientID: client.clientID, previousRefreshToken: nil, requireWriteAccess: true)
        } catch GoogleOAuthError.invalidGrant { throw GoogleOAuthError.exchangeExpired }
    }
}

struct GoogleDesktopClient: Codable, Equatable {
    let clientID: String
    let clientSecret: String

    func validate() throws {
        let pattern = #"^[0-9]{5,30}-[A-Za-z0-9_-]{10,128}\.apps\.googleusercontent\.com$"#
        guard clientID.range(of: pattern, options: .regularExpression) != nil,
              (8...1024).contains(clientSecret.utf8.count),
              clientSecret.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }) else {
            throw GoogleOAuthError.invalidConfiguration
        }
    }

    static func importJSON(_ data: Data) throws -> GoogleDesktopClient {
        guard data.count <= 65536,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["web"] == nil,
              let installed = root["installed"] as? [String: Any],
              let id = installed["client_id"] as? String,
              let secret = installed["client_secret"] as? String else { throw GoogleOAuthError.invalidConfiguration }
        // auth_uri, token_uri, and redirect_uris are deliberately never trusted.
        let client = GoogleDesktopClient(clientID: id, clientSecret: secret)
        try client.validate()
        return client
    }
}

struct GoogleOAuthTokens: Codable {
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let grantedScopes: Set<String>

    var hasWriteAccess: Bool { grantedScopes.contains(GoogleOAuthSecurity.tasksScope) }
    var hasReadAccess: Bool { hasWriteAccess || grantedScopes.contains(GoogleOAuthSecurity.tasksReadOnlyScope) }

    init(clientID: String, accessToken: String, refreshToken: String, expiresAt: Date,
         grantedScopes: Set<String> = [GoogleOAuthSecurity.tasksReadOnlyScope]) {
        self.clientID = clientID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.grantedScopes = grantedScopes
    }

    private enum CodingKeys: String, CodingKey {
        case clientID, accessToken, refreshToken, expiresAt, grantedScopes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try values.decode(String.self, forKey: .clientID)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decode(String.self, forKey: .refreshToken)
        expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        // Versions that did not persist scope requested read-only access. Never
        // infer a write grant from a stored token that lacks scope metadata.
        grantedScopes = try values.decodeIfPresent(Set<String>.self, forKey: .grantedScopes)
            ?? [GoogleOAuthSecurity.tasksReadOnlyScope]
    }
}

enum GoogleOAuthSecurity {
    static let tasksScope = "https://www.googleapis.com/auth/tasks"
    static let tasksReadOnlyScope = "https://www.googleapis.com/auth/tasks.readonly"
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func randomURLSafe(bytes: Int) throws -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        guard status == errSecSuccess else { throw GoogleOAuthError.randomUnavailable }
        return base64URL(data)
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func equalState(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
}

private enum GoogleOAuthKeychain {
    static let service = "com.iuhachicha.floattasks.google"
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    static func read(account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw GoogleOAuthError.keychainRead }
        return data
    }
    static func save(_ data: Data, account: String) throws {
        let request = query(account)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GoogleOAuthError.keychainWrite }
    }
    static func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GoogleOAuthError.keychainRemove }
    }
}

struct GoogleOAuthTokenResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let expires_in: Double?
    let token_type: String?
    let scope: String?
    let error: String?

    func tokens(clientID: String, previousRefreshToken: String?, previousGrantedScopes: Set<String>? = nil,
                requireWriteAccess: Bool = false) throws -> GoogleOAuthTokens {
        guard let access = access_token, !access.isEmpty, access.utf8.count <= 32768,
              let expiry = expires_in, expiry.isFinite, expiry > 0, expiry <= 604800,
              token_type?.lowercased() == "bearer" else { throw GoogleOAuthError.invalidTokenResponse }
        let grantedScopes = scope.map { Set($0.split(separator: " ").map(String.init)) } ?? previousGrantedScopes ?? []
        if requireWriteAccess && !grantedScopes.contains(GoogleOAuthSecurity.tasksScope) {
            throw GoogleOAuthError.tasksWritePermissionMissing
        }
        guard grantedScopes.contains(GoogleOAuthSecurity.tasksScope)
                || grantedScopes.contains(GoogleOAuthSecurity.tasksReadOnlyScope) else {
            throw GoogleOAuthError.tasksPermissionMissing
        }
        guard let refresh = refresh_token ?? previousRefreshToken, !refresh.isEmpty, refresh.utf8.count <= 32768 else {
            throw GoogleOAuthError.refreshTokenMissing
        }
        return GoogleOAuthTokens(clientID: clientID, accessToken: access, refreshToken: refresh,
                                 expiresAt: Date().addingTimeInterval(expiry), grantedScopes: grantedScopes)
    }
}

private final class GoogleOAuthNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private enum GoogleOAuthHTTP {
    static func token(fields: [String: String]) async throws -> GoogleOAuthTokenResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: GoogleOAuthNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = GoogleOAuthSecurity.form(fields)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw GoogleOAuthError.cancelled }
            throw GoogleOAuthError.networkUnavailable
        }
        guard let http = response as? HTTPURLResponse, data.count <= 1048576 else { throw GoogleOAuthError.invalidTokenResponse }
        let parsed = try? JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data)
        if let error = parsed?.error {
            switch error {
            case "invalid_grant": throw GoogleOAuthError.invalidGrant
            case "invalid_client", "unauthorized_client", "deleted_client": throw GoogleOAuthError.clientRejected
            case "access_denied": throw GoogleOAuthError.authorizationDenied
            default: throw GoogleOAuthError.providerRejected
            }
        }
        guard http.statusCode == 200, let parsed else {
            if http.statusCode == 429 || http.statusCode >= 500 { throw GoogleOAuthError.temporarilyUnavailable }
            throw GoogleOAuthError.invalidTokenResponse
        }
        return parsed
    }
}

enum GoogleOAuthCallbackResult {
    case code(String)
    case authorizationError(GoogleOAuthError)
    case reject(Int)
}

enum GoogleOAuthCallbackParser {
    static func parse(_ data: Data, port: UInt16, expectedState: String) -> GoogleOAuthCallbackResult {
        guard data.count <= 32768, let request = String(data: data, encoding: .utf8),
              let headerEnd = request.range(of: "\r\n\r\n") else { return .reject(400) }
        let lines = request[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let first = lines.first else { return .reject(400) }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", ["HTTP/1.1", "HTTP/1.0"].contains(String(parts[2])) else { return .reject(405) }
        let target = String(parts[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              let url = URLComponents(string: target), url.scheme == nil, url.host == nil,
              url.percentEncodedPath == "/oauth/callback", url.fragment == nil else { return .reject(404) }
        guard target.range(of: #"%(?![0-9a-fA-F]{2})"#, options: .regularExpression) == nil else { return .reject(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { return .reject(400) }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { return .reject(400) }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else { return .reject(400) }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else { return .reject(400) }
            query[item.name] = value
        }
        guard let state = query["state"], GoogleOAuthSecurity.equalState(state, expectedState) else { return .reject(403) }
        if let error = query["error"] {
            guard query["code"] == nil else { return .reject(400) }
            return .authorizationError(error == "access_denied" ? .authorizationDenied : .providerRejected)
        }
        guard let code = query["code"], !code.isEmpty, code.utf8.count <= 8192,
              !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .reject(400) }
        return .code(code)
    }
}

final class GoogleOAuthLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.local.floattasks.google.loopback")
    private let listener: NWListener
    private let expectedState: String
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var timeout: DispatchWorkItem?
    private var consumed = false
    private var connections: [UUID: NWConnection] = [:]

    init(expectedState: String) throws {
        self.expectedState = expectedState
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        do { listener = try NWListener(using: parameters) }
        catch { throw GoogleOAuthError.listenerUnavailable }
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let result { continuation.resume(throwing: result.failure ?? GoogleOAuthError.cancelled); return }
                    startContinuation = continuation
                    listener.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(GoogleOAuthError.timedOut)) }
                    timeout = deadline
                    queue.asyncAfter(deadline: .now() + 300, execute: deadline)
                    listener.start(queue: queue)
                }
            }
        }, onCancel: { self.cancel() })
    }

    func authorizationCode() async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let result { continuation.resume(with: result) }
                    else { codeContinuation = continuation }
                }
            }
        }, onCancel: { self.cancel() })
    }

    func cancel() { queue.async { [self] in finish(.failure(GoogleOAuthError.cancelled)) } }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback") else {
                finish(.failure(GoogleOAuthError.listenerUnavailable)); return
            }
            startContinuation?.resume(returning: url)
            startContinuation = nil
        case .failed: finish(.failure(GoogleOAuthError.listenerUnavailable))
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, !consumed, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.close(id) }
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            guard accumulated.count <= 32768 else { self.respond(connection, id: id, status: 400); return }
            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                guard !self.consumed, self.result == nil, let port = self.listener.port else {
                    self.respond(connection, id: id, status: 410); return
                }
                switch GoogleOAuthCallbackParser.parse(accumulated, port: port.rawValue, expectedState: self.expectedState) {
                case .reject(let status): self.respond(connection, id: id, status: status)
                case .code(let code): self.consume(connection, id: id, result: .success(code))
                case .authorizationError(let error): self.consume(connection, id: id, result: .failure(error))
                }
            } else if complete || error != nil { self.close(id) }
            else { self.receive(connection, id: id, buffer: accumulated) }
        }
    }

    private func consume(_ connection: NWConnection, id: UUID, result: Result<String, Error>) {
        consumed = true
        timeout?.cancel()
        listener.cancel()
        respond(connection, id: id, status: 200, authorizationResult: result)
        // Ensure a browser that disconnects while receiving cannot hold sign-in open.
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finish(result) }
    }

    private func respond(_ connection: NWConnection, id: UUID, status: Int, authorizationResult: Result<String, Error>? = nil) {
        let message: String
        if let authorizationResult {
            if case .success = authorizationResult { message = "Return to Float Tasks. Your Mac app is finishing Google sign-in." }
            else { message = "Google sign-in was not completed. Return to Float Tasks to try again." }
        } else { message = "This request is not a valid Float Tasks sign-in callback. You can close this tab." }
        let body = "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Float Tasks</title><body><h1>Float Tasks</h1><p>\(message)</p></body>"
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Rejected")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\nPragma: no-cache\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'; base-uri 'none'\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        connection.send(content: Data((header + body).utf8), completion: .contentProcessed { [weak self] _ in
            self?.close(id)
            if let authorizationResult { self?.finish(authorizationResult) }
        })
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }

    private func finish(_ terminal: Result<String, Error>) {
        guard result == nil else { return }
        result = terminal
        timeout?.cancel()
        timeout = nil
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        startContinuation?.resume(throwing: terminal.failure ?? GoogleOAuthError.cancelled)
        startContinuation = nil
        codeContinuation?.resume(with: terminal)
        codeContinuation = nil
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let error) = self { return error }; return nil }
}

enum GoogleOAuthError: LocalizedError {
    case invalidConfiguration, configurationRead, notConfigured, notSignedIn, alreadyAuthorizing
    case cancelled, timedOut, browserUnavailable, listenerUnavailable, randomUnavailable
    case keychainRead, keychainWrite, keychainRemove
    case authorizationDenied, providerRejected, clientRejected, invalidGrant, signInExpired, exchangeExpired
    case networkUnavailable, temporarilyUnavailable, invalidTokenResponse, tasksPermissionMissing, tasksWritePermissionMissing, refreshTokenMissing

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Choose the JSON downloaded for a Google OAuth client with application type Desktop app. Web-client files and incomplete credentials cannot be used."
        case .configurationRead: return "Couldn’t read that client file. Download the Desktop app JSON from Google Cloud and choose it again."
        case .notConfigured: return "Import a Google Desktop app OAuth client JSON in Settings, then sign in."
        case .notSignedIn: return "Sign in to Google to load your task lists."
        case .alreadyAuthorizing: return "Google sign-in is already open in your browser. Complete it or cancel before trying again."
        case .cancelled: return "Google sign-in was cancelled."
        case .timedOut: return "Google sign-in timed out after five minutes. Choose Sign in to try again."
        case .browserUnavailable: return "Couldn’t open your default browser. Set a default web browser in macOS Settings and try again."
        case .listenerUnavailable: return "Couldn’t open the temporary local sign-in callback. Check whether security software blocks local connections, then try again."
        case .randomUnavailable: return "macOS couldn’t create a secure sign-in request. Restart Float Tasks and try again."
        case .keychainRead: return "Couldn’t read Google credentials from Keychain. Unlock your login keychain and restart Float Tasks, or import your Desktop client again."
        case .keychainWrite: return "Couldn’t save Google credentials in Keychain. Unlock your login keychain and try again."
        case .keychainRemove: return "Couldn’t remove the saved Google sign-in from Keychain. Unlock your login keychain and choose Sign out again."
        case .authorizationDenied: return "Google access wasn’t granted. To edit tasks, sign in again and allow the requested Tasks permission."
        case .providerRejected: return "Google couldn’t authorize this app. Review the Google consent screen and your OAuth project settings, then try again."
        case .clientRejected: return "Google rejected this OAuth client. Import a valid Desktop app client JSON from your Google Cloud project."
        case .invalidGrant, .signInExpired: return "Your saved Google authorization has expired or was revoked. Sign in again to reconnect your tasks."
        case .exchangeExpired: return "Google’s sign-in code expired or was rejected. Choose Sign in and complete a new sign-in."
        case .networkUnavailable: return "Couldn’t connect to Google. Check your internet connection and try again."
        case .temporarilyUnavailable: return "Google is temporarily unavailable or limiting requests. Wait a moment and try again."
        case .invalidTokenResponse: return "Google returned an unexpected sign-in response. Try signing in again."
        case .tasksPermissionMissing: return "Google Tasks read access wasn’t granted. Sign in again and allow the requested Tasks permission."
        case .tasksWritePermissionMissing: return "Google Tasks editing permission wasn’t granted. Your previous connection is unchanged. Enable editing again and allow the requested Tasks permission."
        case .refreshTokenMissing: return "Google didn’t provide an offline sign-in token. Sign in again and complete the consent step."
        }
    }
}
