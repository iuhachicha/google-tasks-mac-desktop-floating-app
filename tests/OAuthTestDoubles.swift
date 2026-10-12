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
    static var returnedScope: String? = GoogleOAuthSecurity.tasksReadOnlyScope
    static var authorizationResponse: GoogleOAuthTokenResponse?
    static func token(fields: [String: String]) async throws -> GoogleOAuthTokenResponse {
        calls += 1
        if fields["grant_type"] == "authorization_code" {
            guard let authorizationResponse else {
                preconditionFailure("Interactive token exchange requires an explicit synthetic response")
            }
            if let nextError { throw nextError }
            return authorizationResponse
        }
        precondition(fields["grant_type"] == "refresh_token", "Unexpected token grant type")
        lastRefreshToken = fields["refresh_token"]
        try await Task.sleep(nanoseconds: 1000000)
        if let nextError { throw nextError }
        return GoogleOAuthTokenResponse(access_token: "renewed-access-fixture", refresh_token: returnedRefreshToken,
                                        expires_in: 3600, token_type: "Bearer", scope: returnedScope, error: nil)
    }
}

@MainActor enum GoogleOAuthTestBrowser {
    // Tests may explicitly intercept an authorization URL and send a synthetic
    // callback to their own IPv4 loopback listener. No browser is ever opened.
    static var openHandler: ((URL) -> Bool)?
    static func open(_ url: URL) -> Bool {
        guard let openHandler else {
            preconditionFailure("Tests must never open a browser or start unplanned authorization")
        }
        return openHandler(url)
    }
}
