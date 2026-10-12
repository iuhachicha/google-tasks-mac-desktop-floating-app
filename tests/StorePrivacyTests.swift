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
    var configuredClientID: String? = "synthetic-client-a"
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
    func importClient(from url: URL) throws {
        if importsChangeClient { isSignedIn = false; configuredClientID = "synthetic-client-b" }
    }
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
    static var preferenceSuites: [String] = []
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
    static func isolatedDefaults() -> UserDefaults {
        let name = "com.floattasks.tests.\(UUID().uuidString)"
        preferenceSuites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
    static func loadedStore(defaults: UserDefaults? = nil, explicitSelection: Bool = true) async throws -> TaskStore {
        try seedAccountA()
        let store = TaskStore(defaults: defaults ?? isolatedDefaults())
        expect(store.lists == accountALists, "Synthetic account A cache failed to load")
        // loadCache reads sign-in once; the initial refresh reads it again.
        // Wait for that scheduled check rather than assuming a number of yields.
        try await waitUntil("Initial auto-refresh did not settle") { store.oauth.signInStatusReads >= 2 }
        store.oauth.isSignedIn = true
        if explicitSelection { store.applySelectedListIDs(["synthetic-list-a"]) }
        return store
    }
    static func expectCleared(_ store: TaskStore) {
        expect(store.lists.isEmpty, "Previous account's tasks remained visible")
        expect(store.lastSynced == nil, "Previous account's sync metadata remained visible")
        expect(!FileManager.default.fileExists(atPath: AppPaths.snapshot.path), "Previous account's task cache remained on disk")
        expect(store.selectedListIDs == nil, "The previous account's list selection was not reset")
    }
    static var visibilityLists: [TaskList] {
        [TaskList(id: "synthetic-alpha", title: "Synthetic visible list", tasks: [
            GoogleTask(id: "synthetic-river", title: "River fixture", notes: "Visible note fixture", due: nil, status: "needsAction", parent: nil),
            GoogleTask(id: "synthetic-tree", title: "Tree fixture", notes: nil, due: nil, status: "needsAction", parent: nil)
        ]), TaskList(id: "synthetic-beta", title: "Synthetic hidden list", tasks: [
            GoogleTask(id: "synthetic-comet", title: "Comet fixture", notes: "Nebula note fixture", due: nil, status: "needsAction", parent: nil)
        ]), TaskList(id: "synthetic-empty", title: "Synthetic empty list", tasks: [])]
    }
    static func refresh(_ store: TaskStore, lists: [TaskList]) async throws {
        GoogleTasksClient.fetch = { _ in lists }
        store.refresh()
        try await waitUntil("Synthetic refresh did not complete") { !store.isLoading && store.lists == lists }
        expect(store.error == nil, "Synthetic refresh reported an error")
    }
    static func visibilityTests() async throws {
        let defaults = isolatedDefaults()
        let store = try await loadedStore(defaults: defaults, explicitSelection: false)
        try await refresh(store, lists: visibilityLists)
        expect(store.selectedListIDs == nil && store.visibleLists == visibilityLists, "Default list selection must include every list")
        expect(store.status == "3 lists · 3 tasks", "Default counts must include all visible lists and tasks")

        store.setListVisible(id: "synthetic-beta", visible: false)
        expect(store.visibleLists.map(\.id) == ["synthetic-alpha", "synthetic-empty"], "Hiding a list changed API order or hid an unrelated list")
        expect(!store.isListVisible(id: "synthetic-beta") && store.isListVisible(id: "synthetic-alpha"), "List visibility lookup disagrees with selection")
        expect(store.status == "2 lists · 2 tasks", "Counts included hidden lists or tasks")
        for query in ["Comet", "Nebula", "Synthetic hidden list"] {
            store.searchText = query
            expect(store.filteredLists.isEmpty, "A hidden list or its tasks appeared in search")
        }
        store.searchText = "River"
        expect(store.filteredLists.map(\.id) == ["synthetic-alpha"], "Search lost a visible matching task")
        store.searchText = ""
        expect(store.lists == visibilityLists, "Hiding a list removed it from the complete data source")
        let cached = try JSONDecoder().decode(TaskSnapshot.self, from: Data(contentsOf: AppPaths.snapshot))
        expect(cached.lists == visibilityLists, "Visibility selection removed lists from the task cache")
        print("PASS: default visibility, per-list toggles, visible counts, complete caching, and search exclude hidden lists correctly")

        store.applySelectedListIDs(["synthetic-beta"])
        expect(store.status == "1 list · 1 task", "Single-list selection must count only that list's task")
        var renamed = visibilityLists
        renamed[1] = TaskList(id: "synthetic-beta", title: "Synthetic renamed list", tasks: renamed[1].tasks)
        renamed.append(TaskList(id: "synthetic-new", title: "Synthetic newly created list", tasks: []))
        try await refresh(store, lists: renamed)
        expect(store.visibleLists.map(\.id) == ["synthetic-beta"], "Refresh or a newly discovered list widened explicit selection")
        expect(store.visibleLists[0].title == "Synthetic renamed list", "Renaming a selected list broke its ID-based selection")
        expect(!store.isListVisible(id: "synthetic-new"), "A new list was shown despite explicit selection")
        store.setListVisible(id: "synthetic-alpha", visible: true)
        expect(store.visibleLists.map(\.id) == ["synthetic-alpha", "synthetic-beta"], "Showing a list did not preserve the API's order")
        print("PASS: selection survives rename and refresh by ID; newly discovered lists stay hidden under explicit selection")

        let relaunched = TaskStore(defaults: defaults)
        expect(relaunched.visibleLists.map(\.id) == ["synthetic-alpha", "synthetic-beta"], "Explicit selection did not survive a new Store instance")
        store.hideAllLists()
        expect(store.selectedListIDs == Set<String>() && store.visibleLists.isEmpty, "Hide all must save an explicit empty selection")
        expect(store.status == "0 lists · 0 tasks", "Hide all did not clear visible counts")
        let allHiddenRelaunch = TaskStore(defaults: defaults)
        expect(allHiddenRelaunch.selectedListIDs == Set<String>() && allHiddenRelaunch.visibleLists.isEmpty, "An empty selection incorrectly reverted to all on relaunch")
        renamed.append(TaskList(id: "synthetic-later", title: "Synthetic later list", tasks: []))
        try await refresh(store, lists: renamed)
        expect(store.visibleLists.isEmpty, "Refresh exposed a list after Hide all")
        store.showAllLists()
        expect(store.selectedListIDs == nil && store.visibleLists == renamed, "Show all did not restore the default selection")
        let allVisibleRelaunch = TaskStore(defaults: defaults)
        expect(allVisibleRelaunch.selectedListIDs == nil && allVisibleRelaunch.visibleLists == renamed, "Show all did not persist across relaunch")
        print("PASS: explicit, none, and all selections persist distinctly across restarts")

        store.applySelectedListIDs(["synthetic-empty"])
        expect(store.visibleLists.map(\.id) == ["synthetic-empty"], "A selected empty list must retain its card")
        expect(store.filteredLists.count == 1 && store.status == "1 list · 0 tasks", "An empty list must remain visible with a zero task count")

        store.applySelectedListIDs(["synthetic-alpha"])
        store.oauth.importsChangeClient = false
        let fixtureURL = AppPaths.support.appendingPathComponent("synthetic-client.json")
        try store.importClient(from: fixtureURL)
        expect(store.selectedListIDs == ["synthetic-alpha"], "Same-client import reset list selection")
        store.oauth.isSignedIn = false
        try store.importClient(from: fixtureURL)
        expect(store.selectedListIDs == ["synthetic-alpha"], "Same-client import while signed out reset list selection")
        store.oauth.importsChangeClient = true
        try store.importClient(from: fixtureURL)
        expectCleared(store)
        let afterClientChange = TaskStore(defaults: defaults)
        expect(afterClientChange.selectedListIDs == nil, "Previous account selection returned after client change and relaunch")
        print("PASS: same-client import preserves selection, while a different client resets it in memory and preferences")
    }
    static func main() async throws {
        guard let isolatedDirectory = ProcessInfo.processInfo.environment["FLOATTASKS_DATA_DIR"],
              !isolatedDirectory.isEmpty,
              ProcessInfo.processInfo.environment["FLOATTASKS_TEST_ISOLATED"] == "1" else {
            fatalError("Store tests must be launched by tests/run.sh with an isolated temporary data directory")
        }
        expect(AppPaths.support.path == URL(fileURLWithPath: isolatedDirectory).path,
               "Test cache was not redirected to the temporary directory")
        defer {
            for name in preferenceSuites {
                UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            }
        }

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
            expect(store.selectedListIDs == ["synthetic-list-a"], "Same-client import unexpectedly reset visibility selection")
            store.oauth.importsChangeClient = true
            try store.importClient(from: syntheticURL)
            expectCleared(store)
            print("PASS: importing a different client clears the previous account while same-client import preserves it")
        }

        try await visibilityTests()

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
