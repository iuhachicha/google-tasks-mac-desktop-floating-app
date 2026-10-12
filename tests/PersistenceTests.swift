import Foundation

@main
struct PersistenceTests {
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    @MainActor static func storeTokens(expiresIn: TimeInterval, refresh: String = "persisted-refresh-fixture") throws {
        let value = GoogleOAuthTokens(clientID: fixtureClient.clientID, accessToken: "persisted-access-fixture", refreshToken: refresh, expiresAt: Date().addingTimeInterval(expiresIn))
        GoogleOAuthKeychain.values["tokens"] = try JSONEncoder().encode(value)
    }
    static let fixtureClient = GoogleDesktopClient(clientID: "123456789012-abcdefghijklmnopqrstuvwx.apps.googleusercontent.com", clientSecret: "synthetic-test-secret")
    @MainActor static func main() async throws {
        GoogleOAuthKeychain.values["desktop-client"] = try JSONEncoder().encode(fixtureClient)
        try storeTokens(expiresIn: 3600)
        let initialLaunch = GoogleOAuth()
        expect(initialLaunch.isConfigured && initialLaunch.isSignedIn, "Fresh launch must restore existing authorization")
        let initialToken = try await initialLaunch.accessToken()
        expect(initialToken == "persisted-access-fixture", "Unexpired cached token must be used")
        expect(GoogleOAuthHTTP.calls == 0, "Fresh valid token must require neither network nor login")

        try storeTokens(expiresIn: -86400)
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

        let immediatelyRelaunched = GoogleOAuth()
        expect(immediatelyRelaunched.isSignedIn, "Relaunch after refresh must stay connected")
        _ = try await immediatelyRelaunched.accessToken()
        expect(GoogleOAuthHTTP.calls == 1, "Relaunch must reuse newly persisted access token")

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

        try storeTokens(expiresIn: -3600)
        GoogleOAuthHTTP.nextError = .invalidGrant
        let revoked = GoogleOAuth()
        do { _ = try await revoked.accessToken(); fatalError("Revoked authorization was ignored") }
        catch GoogleOAuthError.signInExpired {}
        expect(!revoked.isSignedIn && GoogleOAuthKeychain.values["tokens"] == nil, "Google invalid_grant must clear invalid authorization")
        expect(GoogleOAuthKeychain.values["desktop-client"] != nil, "Revocation must preserve app configuration")
        let afterRevocation = GoogleOAuth()
        expect(afterRevocation.isConfigured && !afterRevocation.isSignedIn, "Revoked credential must not return after relaunch")

        GoogleOAuthHTTP.nextError = nil
        try storeTokens(expiresIn: 3600)
        let signedOut = GoogleOAuth()
        try signedOut.signOut()
        let afterSignOut = GoogleOAuth()
        expect(afterSignOut.isConfigured && !afterSignOut.isSignedIn, "Explicit disconnect must survive relaunch")
        print("PASS: persistent relaunch, reuse before expiry, silent refresh after day away, concurrent refresh coalescing, absent/rotated refresh-token preservation, offline retry, invalid_grant clearing, and explicit sign-out. In-memory fixtures only; no Keychain, browser, or network access.")
    }
}
