import Foundation
import Darwin

// These doubles make account changes deterministic. They do not authenticate,
// inspect credentials, open a browser, or use a network transport.
@MainActor final class GoogleOAuth {
    private var signedIn = false
    var signInStatusReads = 0
    var isSignedIn: Bool {
        get { signInStatusReads += 1; return signedIn }
        set { signedIn = newValue }
    }
    var isAuthorizing = false
    var account = "account-a"
    var signInCalls = 0
    var importsChangeClient = true
    func signIn() async throws {
        signInCalls += 1
        isAuthorizing = true
        await Task.yield()
        account = "account-b"
        isSignedIn = true
        isAuthorizing = false
    }
    func signOut() throws { isSignedIn = false }
    func importClient(from url: URL) throws { if importsChangeClient { isSignedIn = false } }
}

@MainActor final class GoogleTasksClient {
    static var fetch: (String) async throws -> [TaskList] = { _ in throw StoreTestError.fetchFailed }
    private let oauth: GoogleOAuth
    init(oauth: GoogleOAuth) { self.oauth = oauth }
    func fetchLists() async throws -> [TaskList] { try await Self.fetch(oauth.account) }
}

enum StoreTestError: Error { case fetchFailed }

@main @MainActor
struct StorePrivacyTests {
    static let accountALists = [TaskList(id: "synthetic-list-a", title: "Synthetic account A", tasks: [
        GoogleTask(id: "synthetic-task-a", title: "Synthetic account A task", notes: nil,
                   due: nil, status: "needsAction", parent: nil)
    ])]
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    static func waitUntil(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { fatalError(message) }
            try await Task.sleep(nanoseconds: 1000000)
        }
    }
    static func seedAccountA() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try AppPaths.save(TaskSnapshot(version: 1, source: "google_api", capturedAt: now,
                                      sourceURL: "https://tasks.google.com/tasks/",
                                      lists: accountALists, receivedAt: now))
    }
    static func loadedStore() async throws -> TaskStore {
        try seedAccountA()
        let store = TaskStore()
        expect(store.lists == accountALists, "Synthetic account A cache failed to load")
        // loadCache reads sign-in once; the initial refresh reads it again.
        // Wait for that scheduled check rather than assuming a number of yields.
        try await waitUntil("Initial auto-refresh did not settle") { store.oauth.signInStatusReads >= 2 }
        store.oauth.isSignedIn = true
        return store
    }
    static func expectCleared(_ store: TaskStore) {
        expect(store.lists.isEmpty, "Previous account's tasks remained visible")
        expect(store.lastSynced == nil, "Previous account's sync metadata remained visible")
        expect(!FileManager.default.fileExists(atPath: AppPaths.snapshot.path), "Previous account's task cache remained on disk")
    }
    static func main() async throws {
        guard let isolatedDirectory = ProcessInfo.processInfo.environment["FLOATTASKS_DATA_DIR"],
              !isolatedDirectory.isEmpty,
              ProcessInfo.processInfo.environment["FLOATTASKS_TEST_ISOLATED"] == "1" else {
            fatalError("Store tests must be launched by tests/run.sh with an isolated temporary data directory")
        }
        expect(AppPaths.support.path == URL(fileURLWithPath: isolatedDirectory).path,
               "Test cache was not redirected to the temporary directory")

        do {
            let store = try await loadedStore()
            var fetchedB = false
            GoogleTasksClient.fetch = { account in
                expect(account == "account-b", "Sync used the old account after sign-in")
                fetchedB = true
                throw StoreTestError.fetchFailed
            }
            store.connect()
            expectCleared(store)
            try await waitUntil("Account B failure did not complete") { fetchedB && !store.isLoading && store.error != nil }
            expect(store.oauth.account == "account-b" && store.oauth.isSignedIn, "Synthetic sign-in did not switch account")
            expectCleared(store)
            print("PASS: switching to account B clears account A before authorization and keeps it cleared when B's first fetch fails")
        }

        do {
            let store = try await loadedStore()
            var oldFetch: CheckedContinuation<[TaskList], Never>?
            var oldFetchReturned = false
            var fetchedB = false
            GoogleTasksClient.fetch = { account in
                if account == "account-a" {
                    let result = await withCheckedContinuation { oldFetch = $0 }
                    oldFetchReturned = true
                    return result
                }
                fetchedB = true
                throw StoreTestError.fetchFailed
            }
            store.refresh()
            try await waitUntil("Account A sync did not begin") { oldFetch != nil }
            store.connect()
            expectCleared(store)
            try await waitUntil("Account B failure did not complete") { fetchedB && !store.isLoading && store.error != nil }
            oldFetch?.resume(returning: accountALists)
            oldFetch = nil
            try await waitUntil("Cancelled account A response did not return") { oldFetchReturned }
            await Task.yield()
            expectCleared(store)
            print("PASS: a late response from the cancelled account A sync cannot repopulate account B's view or cache")
        }

        do {
            let store = try await loadedStore()
            var oldFetch: CheckedContinuation<[TaskList], Never>?
            var oldFetchReturned = false
            GoogleTasksClient.fetch = { _ in
                let result = await withCheckedContinuation { oldFetch = $0 }
                oldFetchReturned = true
                return result
            }
            store.refresh()
            try await waitUntil("Disconnect test sync did not begin") { oldFetch != nil }
            store.disconnect()
            expectCleared(store)
            expect(!store.oauth.isSignedIn && !store.isLoading, "Disconnect did not clear connection state")
            oldFetch?.resume(returning: accountALists)
            oldFetch = nil
            try await waitUntil("Disconnected sync did not finish") { oldFetchReturned }
            await Task.yield()
            expectCleared(store)
            print("PASS: disconnect clears cached tasks and rejects an in-flight response")
        }

        do {
            let store = try await loadedStore()
            let syntheticURL = AppPaths.support.appendingPathComponent("synthetic-client.json")
            store.oauth.importsChangeClient = false
            try store.importClient(from: syntheticURL)
            expect(store.lists == accountALists, "Reimporting the same client unnecessarily cleared the current account")
            store.oauth.importsChangeClient = true
            try store.importClient(from: syntheticURL)
            expectCleared(store)
            print("PASS: importing a different client clears the previous account while same-client import preserves it")
        }

        if geteuid() != 0 {
            let store = try await loadedStore()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: AppPaths.support.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: AppPaths.support.path) }
            store.connect()
            await Task.yield()
            expect(store.oauth.signInCalls == 0, "Authorization started even though the prior account's cache could not be deleted")
            expect(store.error?.contains("Sign-in was not started") == true, "Cache deletion failure was not reported")
            expect(store.lists.isEmpty, "Cache deletion failure left old tasks visible")
            print("PASS: a cache deletion failure blocks new authorization")
        } else {
            print("SKIP: filesystem permission-denial case is not meaningful when running as root")
        }
        print("Store privacy tests passed. Synthetic account labels and temporary files only; no account, Keychain, browser, or network access.")
    }
}
