import Foundation

@main
struct PersistenceTests {
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    @MainActor static func storeTokens(expiresIn: TimeInterval, refresh: String = "persisted-refresh-fixture",
                                      scopes: Set<String> = [GoogleOAuthSecurity.tasksReadOnlyScope], legacy: Bool = false) throws {
        let value = GoogleOAuthTokens(clientID: fixtureClient.clientID, accessToken: "persisted-access-fixture",
                                      refreshToken: refresh, expiresAt: Date().addingTimeInterval(expiresIn), grantedScopes: scopes)
        let data = try JSONEncoder().encode(value)
        if legacy {
            var original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            original.removeValue(forKey: "grantedScopes")
            GoogleOAuthKeychain.values["tokens"] = try JSONSerialization.data(withJSONObject: original)
        } else {
            GoogleOAuthKeychain.values["tokens"] = data
        }
    }
    static let fixtureClient = GoogleDesktopClient(clientID: "123456789012-abcdefghijklmnopqrstuvwx.apps.googleusercontent.com", clientSecret: "synthetic-test-secret")

    @MainActor static func syntheticSignIn(_ oauth: GoogleOAuth, scope: String?, denied: Bool = false) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        var callbackTask: Task<Void, Never>?
        GoogleOAuthHTTP.authorizationResponse = GoogleOAuthTokenResponse(access_token: "authorized-access-fixture",
            refresh_token: "authorized-refresh-fixture", expires_in: 3600, token_type: "Bearer", scope: scope, error: nil)
        GoogleOAuthTestBrowser.openHandler = { authorization in
            let components = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!
            expect(components.scheme == "https" && components.host == "accounts.google.com", "Unexpected authorization origin")
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            expect(query["scope"] == GoogleOAuthSecurity.tasksScope, "Interactive sign-in must request full Tasks access")
            expect(query["code_challenge_method"] == "S256" && !(query["code_challenge"] ?? "").isEmpty,
                   "Permission migration lost PKCE")
            expect(query["prompt"] == "consent", "Permission migration must request consent")
            var callback = URLComponents(string: query["redirect_uri"]!)!
            expect(callback.scheme == "http" && callback.host == "127.0.0.1" && callback.port != nil
                   && callback.path == "/oauth/callback", "Synthetic authorization must target only its local listener")
            callback.queryItems = [URLQueryItem(name: "state", value: query["state"]),
                                   URLQueryItem(name: denied ? "error" : "code", value: denied ? "access_denied" : "synthetic-authorization-code")]
            let callbackURL = callback.url!
            callbackTask = Task { @MainActor in
                do { _ = try await session.data(from: callbackURL) }
                catch { preconditionFailure("Synthetic loopback callback did not complete") }
            }
            return true
        }
        defer {
            callbackTask?.cancel()
            session.invalidateAndCancel()
            GoogleOAuthTestBrowser.openHandler = nil
            GoogleOAuthHTTP.authorizationResponse = nil
        }
        do {
            try await oauth.signIn()
            await callbackTask?.value
        } catch {
            await callbackTask?.value
            throw error
        }
    }

    @MainActor static func migrationTests() async throws {
        try storeTokens(expiresIn: 3600, legacy: true)
        let upgraded = GoogleOAuth()
        expect(!upgraded.hasWriteAccess, "Legacy authorization must start read-only")
        try await syntheticSignIn(upgraded, scope: GoogleOAuthSecurity.tasksScope)
        expect(upgraded.isSignedIn && upgraded.hasWriteAccess, "Explicit full grant did not enable editing")
        let saved = try JSONDecoder().decode(GoogleOAuthTokens.self, from: GoogleOAuthKeychain.values["tokens"]!)
        expect(saved.hasWriteAccess && saved.refreshToken == "authorized-refresh-fixture", "Full grant was not saved with its new tokens")
        expect(GoogleOAuth().hasWriteAccess, "Editing permission was lost on relaunch")

        for scope in [GoogleOAuthSecurity.tasksReadOnlyScope, nil] {
            try storeTokens(expiresIn: 3600, legacy: true)
            let existing = GoogleOAuth()
            let previousData = GoogleOAuthKeychain.values["tokens"]
            do {
                try await syntheticSignIn(existing, scope: scope)
                fatalError("Insufficient permission silently completed migration")
            } catch GoogleOAuthError.tasksWritePermissionMissing {}
            expect(existing.isSignedIn && !existing.hasWriteAccess, "Insufficient grant changed legacy authorization")
            expect(GoogleOAuthKeychain.values["tokens"] == previousData, "Insufficient grant replaced the existing credential")
            let retained = try await existing.accessToken()
            expect(retained == "persisted-access-fixture", "Reading stopped after an unsuccessful permission upgrade")
        }

        try storeTokens(expiresIn: 3600, legacy: true)
        let denied = GoogleOAuth()
        let beforeDenied = GoogleOAuthKeychain.values["tokens"]
        do {
            try await syntheticSignIn(denied, scope: nil, denied: true)
            fatalError("Consent denial silently completed migration")
        } catch GoogleOAuthError.authorizationDenied {}
        expect(denied.isSignedIn && !denied.hasWriteAccess, "Denial discarded a valid read-only connection")
        expect(GoogleOAuthKeychain.values["tokens"] == beforeDenied, "Denial changed stored credentials")

        let cancelled = GoogleOAuth()
        var intercepted = false
        GoogleOAuthTestBrowser.openHandler = { _ in intercepted = true; return true }
        let pending = Task { @MainActor in try await cancelled.signIn() }
        for _ in 0..<2000 {
            if intercepted { break }
            try await Task.sleep(nanoseconds: 1000000)
        }
        expect(intercepted, "Synthetic sign-in did not reach browser interception")
        cancelled.cancelSignIn()
        do { try await pending.value; fatalError("Cancelled migration completed") }
        catch GoogleOAuthError.cancelled {}
        GoogleOAuthTestBrowser.openHandler = nil
        expect(cancelled.isSignedIn && !cancelled.hasWriteAccess, "Cancellation discarded a valid read-only connection")
        expect(GoogleOAuthKeychain.values["tokens"] == beforeDenied, "Cancellation changed stored credentials")
        let retained = try await cancelled.accessToken()
        expect(retained == "persisted-access-fixture", "Reading stopped after cancelled migration")
        print("PASS: full-scope migration and relaunch; read-only, missing-scope, denied, and cancelled upgrades preserve prior credentials")
    }

    @MainActor static func main() async throws {
        GoogleOAuthKeychain.values["desktop-client"] = try JSONEncoder().encode(fixtureClient)
        try storeTokens(expiresIn: 3600, legacy: true)
        let initialLaunch = GoogleOAuth()
        expect(initialLaunch.isConfigured && initialLaunch.isSignedIn, "Fresh launch must restore existing authorization")
        expect(!initialLaunch.hasWriteAccess, "Legacy tokens without persisted scope must remain read-only")
        let initialToken = try await initialLaunch.accessToken()
        expect(initialToken == "persisted-access-fixture", "Unexpired cached token must be used")
        expect(GoogleOAuthHTTP.calls == 0, "Fresh valid token must require neither network nor login")

        try storeTokens(expiresIn: -86400, legacy: true)
        GoogleOAuthHTTP.returnedScope = nil
        let afterDayAway = GoogleOAuth()
        expect(afterDayAway.isSignedIn, "Access-token expiry must not discard persistent sign-in")
        async let first = afterDayAway.accessToken()
        async let second = afterDayAway.accessToken()
        let (firstToken, secondToken) = try await (first, second)
        expect(firstToken == "renewed-access-fixture" && secondToken == firstToken, "Silent refresh must complete")
        expect(GoogleOAuthHTTP.calls == 1, "Concurrent consumers must share one silent refresh")
        expect(GoogleOAuthHTTP.lastRefreshToken == "persisted-refresh-fixture", "Silent refresh must use saved refresh token")
        let saved = try JSONDecoder().decode(GoogleOAuthTokens.self, from: GoogleOAuthKeychain.values["tokens"]!)
        expect(saved.refreshToken == "persisted-refresh-fixture", "Omitted refresh_token must preserve long-term credential")
        expect(saved.expiresAt.timeIntervalSinceNow > 3500, "Updated expiry must be persisted")
        expect(!saved.hasWriteAccess && !afterDayAway.hasWriteAccess, "Omitted refresh scope promoted legacy tokens to write access")

        let immediatelyRelaunched = GoogleOAuth()
        expect(immediatelyRelaunched.isSignedIn, "Relaunch after refresh must stay connected")
        _ = try await immediatelyRelaunched.accessToken()
        expect(GoogleOAuthHTTP.calls == 1, "Relaunch must reuse newly persisted access token")
        expect(!immediatelyRelaunched.hasWriteAccess, "Relaunch promoted a migrated read-only token")

        try storeTokens(expiresIn: -3600, scopes: [GoogleOAuthSecurity.tasksScope])
        let fullGrant = GoogleOAuth()
        expect(fullGrant.hasWriteAccess, "Stored full grant did not restore editing")
        _ = try await fullGrant.accessToken()
        expect(fullGrant.hasWriteAccess && GoogleOAuth().hasWriteAccess, "Omitted refresh scope lost a recorded full grant")
        try storeTokens(expiresIn: -3600, scopes: [GoogleOAuthSecurity.tasksScope])
        GoogleOAuthHTTP.returnedScope = GoogleOAuthSecurity.tasksReadOnlyScope
        let reducedGrant = GoogleOAuth()
        _ = try await reducedGrant.accessToken()
        expect(reducedGrant.isSignedIn && !reducedGrant.hasWriteAccess && !GoogleOAuth().hasWriteAccess,
               "Explicitly reduced refresh scope retained write access")

        try storeTokens(expiresIn: -3600)
        GoogleOAuthHTTP.returnedRefreshToken = "rotated-refresh-fixture"
        let rotatingSession = GoogleOAuth()
        _ = try await rotatingSession.accessToken()
        let rotated = try JSONDecoder().decode(GoogleOAuthTokens.self, from: GoogleOAuthKeychain.values["tokens"]!)
        expect(rotated.refreshToken == "rotated-refresh-fixture", "Refresh-token rotation must be saved for future launches")

        try storeTokens(expiresIn: -3600, refresh: "rotated-refresh-fixture")
        GoogleOAuthHTTP.returnedRefreshToken = nil
        GoogleOAuthHTTP.nextError = .networkUnavailable
        let offlineLaunch = GoogleOAuth()
        do { _ = try await offlineLaunch.accessToken(); fatalError("Network failure was ignored") }
        catch GoogleOAuthError.networkUnavailable {}
        expect(offlineLaunch.isSignedIn && GoogleOAuthKeychain.values["tokens"] != nil, "Temporary network failure must retain sign-in")
        GoogleOAuthHTTP.nextError = nil
        _ = try await offlineLaunch.accessToken()
        expect(GoogleOAuthHTTP.lastRefreshToken == "rotated-refresh-fixture", "Retry must retain rotated credential")

        try storeTokens(expiresIn: -3600, scopes: [GoogleOAuthSecurity.tasksScope])
        GoogleOAuthHTTP.nextError = .invalidGrant
        let revoked = GoogleOAuth()
        do { _ = try await revoked.accessToken(); fatalError("Revoked authorization was ignored") }
        catch GoogleOAuthError.signInExpired {}
        expect(!revoked.isSignedIn && GoogleOAuthKeychain.values["tokens"] == nil, "Google invalid_grant must clear invalid authorization")
        expect(!revoked.hasWriteAccess, "Revoked authorization retained editing permission")
        expect(GoogleOAuthKeychain.values["desktop-client"] != nil, "Revocation must preserve app configuration")
        let afterRevocation = GoogleOAuth()
        expect(afterRevocation.isConfigured && !afterRevocation.isSignedIn, "Revoked credential must not return after relaunch")

        GoogleOAuthHTTP.nextError = nil
        try storeTokens(expiresIn: 3600, scopes: [GoogleOAuthSecurity.tasksScope])
        let signedOut = GoogleOAuth()
        try signedOut.signOut()
        let afterSignOut = GoogleOAuth()
        expect(afterSignOut.isConfigured && !afterSignOut.isSignedIn, "Explicit disconnect must survive relaunch")
        expect(!signedOut.hasWriteAccess && !afterSignOut.hasWriteAccess, "Sign-out retained editing permission")
        try await migrationTests()
        print("PASS: legacy restoration, scope persistence and downgrade, token reuse, silent concurrent refresh, refresh-token rotation, offline retry, revocation, and sign-out. In-memory fixtures and local callbacks only; no Keychain, browser, or account network access.")
    }
}
