import Foundation

@main
struct OAuthTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
    static func expectThrows(_ operation: () throws -> Void, _ message: String) {
        do { try operation(); fatalError(message) } catch {}
    }
    static func request(_ target: String, host: String = "127.0.0.1:49152", method: String = "GET", extraHeaders: String = "") -> Data {
        Data("\(method) \(target) HTTP/1.1\r\nHost: \(host)\r\n\(extraHeaders)\r\n".utf8)
    }
    static func rejected(_ data: Data, _ expected: Int) {
        guard case .reject(let actual) = GoogleOAuthCallbackParser.parse(data, port: 49152, expectedState: "secure-state") else { fatalError("Unsafe callback accepted") }
        expect(actual == expected, "Wrong callback rejection")
    }
    static func main() async throws {
        let challenge = GoogleOAuthSecurity.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 challenge vector failed")
        let random = try GoogleOAuthSecurity.randomURLSafe(bytes: 32)
        expect(random.count == 43, "PKCE verifier length")
        expect(random.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil, "Verifier alphabet")
        let nextRandom = try GoogleOAuthSecurity.randomURLSafe(bytes: 32)
        expect(random != nextRandom, "Random values repeat")
        expect(GoogleOAuthSecurity.equalState("same", "same"), "State equality")
        expect(!GoogleOAuthSecurity.equalState("same", "samu"), "State mismatch")
        expect(!GoogleOAuthSecurity.equalState("same", "sam"), "State length")
        let form = String(data: GoogleOAuthSecurity.form(["code": "a+b /?&=", "client_secret": "a&b"]), encoding: .utf8)!
        expect(form == "client_secret=a%26b&code=a%2Bb%20%2F%3F%26%3D", "Form encoding must protect every token delimiter")

        let configuration = Data(#"{"installed":{"client_id":"123456789012-abcdefghijklmnopqrstuvwx.apps.googleusercontent.com","client_secret":"test-secret-fixture","token_uri":"https://attacker.invalid/token"}}"#.utf8)
        let parsed = try GoogleDesktopClient.importJSON(configuration)
        expect(parsed.clientID.hasSuffix(".apps.googleusercontent.com"), "Desktop JSON parsing")
        expectThrows({ _ = try GoogleDesktopClient.importJSON(Data(#"{"web":{"client_id":"bad","client_secret":"bad"}}"#.utf8)) }, "Web configuration accepted")
        expectThrows({ _ = try GoogleDesktopClient.importJSON(Data(#"{"installed":{"client_id":"fake.apps.googleusercontent.com","client_secret":"test-secret-fixture"}}"#.utf8)) }, "Bogus client ID accepted")
        expectThrows({ _ = try GoogleDesktopClient.importJSON(Data(#"{"installed":{"client_id":"123456789012-abcdefghijklmnopqrstuvwx.apps.googleusercontent.com","client_secret":""}}"#.utf8)) }, "Empty client secret accepted")
        expectThrows({ _ = try GoogleDesktopClient.importJSON(Data(repeating: 65, count: 65537)) }, "Oversized configuration accepted")

        let callback = "/oauth/callback?state=secure-state&code=fixture-code%2B%2F"
        guard case .code(let code) = GoogleOAuthCallbackParser.parse(request(callback), port: 49152, expectedState: "secure-state") else { fatalError("Valid callback rejected") }
        expect(code == "fixture-code+/", "Callback code must decode exactly once")
        rejected(request("/oauth/callback?state=wrong&code=x"), 403)
        rejected(request("/oauth/callback?code=x"), 403)
        rejected(request("/other?state=secure-state&code=x"), 404)
        rejected(request("/oauth%2Fcallback?state=secure-state&code=x"), 404)
        rejected(request(callback, host: "attacker.invalid"), 400)
        rejected(request(callback, method: "POST"), 405)
        rejected(request("/oauth/callback?state=secure-state&state=secure-state&code=x"), 400)
        rejected(request("/oauth/callback?state=secure-state&code=x&error=access_denied"), 400)
        rejected(request("/oauth/callback?state=secure-state&code=%ZZ"), 400)
        rejected(request(callback, extraHeaders: "Host: 127.0.0.1:49152\r\n"), 400)
        rejected(request(callback, extraHeaders: "Transfer-Encoding: chunked\r\n"), 400)
        rejected(request(callback, extraHeaders: "Content-Length: 100\r\n"), 400)
        guard case .authorizationError(.authorizationDenied) = GoogleOAuthCallbackParser.parse(request("/oauth/callback?state=secure-state&error=access_denied"), port: 49152, expectedState: "secure-state") else { fatalError("Consent denial not recognized") }

        let response = try JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: Data(#"{"access_token":"fixture-access","expires_in":3600,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/tasks.readonly"}"#.utf8))
        let tokens = try response.tokens(clientID: "test-id", previousRefreshToken: "fixture-refresh")
        expect(tokens.refreshToken == "fixture-refresh", "Refresh response must preserve refresh token")
        expect(!tokens.hasWriteAccess && tokens.hasReadAccess, "Read-only grant must never permit editing")
        expectThrows({ _ = try response.tokens(clientID: "test-id", previousRefreshToken: nil) }, "Initial authorization without refresh token accepted")
        let missingScope = try JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"token_type":"Bearer","scope":"email"}"#.utf8))
        expectThrows({ _ = try missingScope.tokens(clientID: "test-id", previousRefreshToken: nil) }, "Insufficient Tasks scope accepted")
        let writeResponse = GoogleOAuthTokenResponse(access_token: "fixture-access", refresh_token: "fixture-refresh",
            expires_in: 3600, token_type: "Bearer", scope: GoogleOAuthSecurity.tasksScope, error: nil)
        let writeTokens = try writeResponse.tokens(clientID: "test-id", previousRefreshToken: nil, requireWriteAccess: true)
        expect(writeTokens.hasWriteAccess && writeTokens.hasReadAccess, "Full Tasks grant must permit reading and editing")
        let readResponse = GoogleOAuthTokenResponse(access_token: "fixture-access", refresh_token: "fixture-refresh",
            expires_in: 3600, token_type: "Bearer", scope: GoogleOAuthSecurity.tasksReadOnlyScope, error: nil)
        do {
            _ = try readResponse.tokens(clientID: "test-id", previousRefreshToken: nil, requireWriteAccess: true)
            fatalError("Read-only response silently enabled editing")
        } catch GoogleOAuthError.tasksWritePermissionMissing {}
        let omittedScope = GoogleOAuthTokenResponse(access_token: "fixture-access", refresh_token: "fixture-refresh",
            expires_in: 3600, token_type: "Bearer", scope: nil, error: nil)
        expectThrows({ _ = try omittedScope.tokens(clientID: "test-id", previousRefreshToken: nil, requireWriteAccess: true) },
                     "An unconfirmed new scope was treated as a write grant")
        let renewedWrite = try omittedScope.tokens(clientID: "test-id", previousRefreshToken: "fixture-refresh",
                                                   previousGrantedScopes: writeTokens.grantedScopes)
        expect(renewedWrite.hasWriteAccess, "Omitted refresh scope must retain the recorded full grant")
        let renewedRead = try omittedScope.tokens(clientID: "test-id", previousRefreshToken: "fixture-refresh",
                                                  previousGrantedScopes: tokens.grantedScopes)
        expect(!renewedRead.hasWriteAccess, "Omitted refresh scope must never upgrade a read-only grant")
        let lookalikeScope = GoogleOAuthTokenResponse(access_token: "fixture-access", refresh_token: "fixture-refresh",
            expires_in: 3600, token_type: "Bearer", scope: GoogleOAuthSecurity.tasksScope + ".other", error: nil)
        expectThrows({ _ = try lookalikeScope.tokens(clientID: "test-id", previousRefreshToken: nil, requireWriteAccess: true) },
                     "Scope comparison accepted a prefix match instead of an exact grant")

        // Ephemeral, cookie-free session; requests are confined to this test's
        // IPv4 loopback listener and never reach Google or another remote host.
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.urlCache = nil
        sessionConfiguration.connectionProxyDictionary = [:]
        sessionConfiguration.timeoutIntervalForRequest = 5
        sessionConfiguration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let listener = try GoogleOAuthLoopback(expectedState: "integration-state")
        let url = try await listener.start()
        expect(url.host == "127.0.0.1" && url.port != nil && url.path == "/oauth/callback", "Listener redirect address")
        let inspect = Process()
        inspect.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        inspect.arguments = ["-nP", "-a", "-p", String(ProcessInfo.processInfo.processIdentifier), "-iTCP:\(url.port!)", "-sTCP:LISTEN"]
        let output = Pipe(); inspect.standardOutput = output
        try inspect.run(); inspect.waitUntilExit()
        let binding = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        expect(binding.contains("127.0.0.1:\(url.port!)"), "Listener must bind IPv4 loopback, not every interface")
        expect(!binding.contains("*:\(url.port!)"), "Wildcard binding is forbidden")
        var invalid = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        invalid.queryItems = [URLQueryItem(name: "state", value: "wrong"), URLQueryItem(name: "code", value: "bad-code")]
        let (_, rejectedResponse) = try await session.data(from: invalid.url!)
        expect((rejectedResponse as? HTTPURLResponse)?.statusCode == 403, "Invalid state should be rejected without ending sign-in")
        var valid = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        valid.queryItems = [URLQueryItem(name: "state", value: "integration-state"), URLQueryItem(name: "code", value: "integration-code")]
        async let acceptedCode = listener.authorizationCode()
        let (html, acceptedResponse) = try await session.data(from: valid.url!)
        expect((acceptedResponse as? HTTPURLResponse)?.statusCode == 200, "Valid callback HTTP response")
        expect(!String(data: html, encoding: .utf8)!.contains("integration-code"), "Browser response must never reflect credentials")
        let receivedCode = try await acceptedCode
        expect(receivedCode == "integration-code", "Listener lost valid callback")
        listener.cancel()
        do {
            _ = try await session.data(from: valid.url!)
            fatalError("One-time callback listener remained reachable")
        } catch is URLError { }

        let cancelled = try GoogleOAuthLoopback(expectedState: "cancel-state")
        _ = try await cancelled.start()
        async let pending = cancelled.authorizationCode()
        cancelled.cancel()
        do { _ = try await pending; fatalError("Cancelled listener succeeded") }
        catch GoogleOAuthError.cancelled {}
        print("PASS: PKCE RFC vector, cryptographic state, configuration rejection, form encoding, callback security, refresh semantics, real IPv4 loopback binding, wrong-state recovery, one-time callback and cancellation. Synthetic values only; no Keychain, browser, or account network access.")
    }
}
