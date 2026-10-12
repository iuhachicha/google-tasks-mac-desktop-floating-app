import Foundation

// No Security API or network calls are made by these mocks. All values are synthetic test fixtures.
@MainActor enum GoogleOAuthKeychain {
    static var values: [String: Data] = [:]
    static func read(account: String) throws -> Data? { values[account] }
    static func save(_ data: Data, account: String) throws { values[account] = data }
    static func remove(account: String) throws { values.removeValue(forKey: account) }
}
@MainActor enum GoogleOAuthHTTP {
    static var calls = 0
    static var nextError: GoogleOAuthError?
    static var lastRefreshToken: String?
    static var returnedRefreshToken: String?
    static func token(fields: [String: String]) async throws -> GoogleOAuthTokenResponse {
        calls += 1
        precondition(fields["grant_type"] == "refresh_token", "Persistence must never silently launch a new interactive sign-in")
        lastRefreshToken = fields["refresh_token"]
        try await Task.sleep(nanoseconds: 1000000)
        if let nextError { throw nextError }
        return GoogleOAuthTokenResponse(access_token: "renewed-access-fixture", refresh_token: returnedRefreshToken,
                                        expires_in: 3600, token_type: "Bearer", scope: GoogleOAuthSecurity.tasksScope, error: nil)
    }
}

@MainActor enum GoogleOAuthTestBrowser {
    static func open(_ url: URL) -> Bool {
        preconditionFailure("Tests must never open a browser or start real Google authorization")
    }
}
