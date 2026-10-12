import Foundation
import Darwin
import Combine

// These doubles make account changes deterministic. They do not authenticate,
// inspect credentials, open a browser, or use a network transport.
@MainActor final class GoogleOAuth: ObservableObject {
    @Published var hasWriteAccess = false
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
    var signInFails = false
    func signIn() async throws {
        signInCalls += 1
        isAuthorizing = true
        await Task.yield()
        if signInFails { isAuthorizing = false; throw StoreTestError.fetchFailed }
        account = "account-b"
        isSignedIn = true
        hasWriteAccess = true
        isAuthorizing = false
    }
    func signOut() throws { isSignedIn = false; hasWriteAccess = false }
    func importClient(from url: URL) throws {
        if importsChangeClient { isSignedIn = false; configuredClientID = "synthetic-client-b" }
    }
}

@MainActor final class GoogleTasksClient {
    static var fetch: (String) async throws -> [TaskList] = { _ in throw StoreTestError.fetchFailed }
    static var write: (String, String, String?) async throws -> GoogleTask = { _, _, _ in throw StoreTestError.fetchFailed }
    static var remove: (String, String) async throws -> Void = { _, _ in throw StoreTestError.fetchFailed }
    private let oauth: GoogleOAuth
    init(oauth: GoogleOAuth) { self.oauth = oauth }
    func fetchLists() async throws -> [TaskList] { try await Self.fetch(oauth.account) }
    func createTask(listID: String, title: String) async throws -> GoogleTask { try await Self.write("create", listID, nil) }
    func updateTask(listID: String, taskID: String, title: String, notes: String?, due: Date?) async throws -> GoogleTask { try await Self.write("update", listID, taskID) }
    func setCompleted(listID: String, taskID: String, completed: Bool) async throws -> GoogleTask { try await Self.write(completed ? "complete" : "reopen", listID, taskID) }
    func deleteTask(listID: String, taskID: String) async throws { try await Self.remove(listID, taskID) }
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

    static func mutationTests() async throws {
        let list = accountALists[0]
        let created = GoogleTask(id: "synthetic-created", title: "Synthetic new task", notes: nil,
                                 due: nil, status: "needsAction", parent: nil)
        do {
            let store = try await loadedStore()
            var writes = 0
            GoogleTasksClient.write = { _, _, _ in writes += 1; return created }
            let readonlyResult = await store.addTask(title: created.title, list: list)
            expect(!readonlyResult && writes == 0, "A readonly connection attempted a write")
            store.oauth.hasWriteAccess = true
            store.hideAllLists()
            let hiddenResult = await store.addTask(title: created.title, list: list)
            expect(!hiddenResult && writes == 0, "A hidden list was writable")
            store.applySelectedListIDs([list.id])
            let staleResult = await store.updateTask(task: created, list: list, title: "Synthetic edit", notes: "", due: nil)
            expect(!staleResult && writes == 0, "A stale task outside the list was writable")
            expect(store.lists == accountALists, "Rejected writes changed the task view")
            print("PASS: readonly, hidden-list, and stale-task writes are rejected before transport")
        }
        do {
            let store = try await loadedStore()
            store.oauth.hasWriteAccess = true
            var response: CheckedContinuation<GoogleTask, Never>?
            var writes = 0
            GoogleTasksClient.write = { action, listID, _ in
                expect(action == "create" && listID == list.id, "Create targeted the wrong endpoint or list")
                writes += 1
                return await withCheckedContinuation { response = $0 }
            }
            GoogleTasksClient.fetch = { _ in throw StoreTestError.fetchFailed }
            let first = Task { await store.addTask(title: created.title, list: list) }
            try await waitUntil("Create did not start") { response != nil }
            expect(store.isMutating && store.lists == accountALists, "An unconfirmed write changed the task view")
            let duplicate = await store.addTask(title: created.title, list: list)
            expect(!duplicate && writes == 1, "A double submission created a duplicate request")
            response?.resume(returning: created)
            let firstResult = await first.value
            expect(firstResult, "A successful write was reported as failed")
            try await waitUntil("Post-write refresh did not settle") { !store.isLoading }
            expect(!store.isMutating && store.lists[0].tasks.contains(created), "Confirmed create was lost after refresh failed")
            let cache = try JSONDecoder().decode(TaskSnapshot.self, from: Data(contentsOf: AppPaths.snapshot))
            expect(cache.lists[0].tasks.contains(created), "Confirmed create was not saved in the offline cache")
            expect(writes == 1, "Write was retried after refresh failed")
            print("PASS: writes wait for confirmation, serialize submissions, cache success, and never retry after a failed follow-up read")
        }
        do {
            let store = try await loadedStore()
            store.oauth.hasWriteAccess = true
            var writes = 0
            GoogleTasksClient.write = { action, listID, _ in
                expect(action == "create" && listID == list.id, "Cache-failure fixture targeted the wrong task list")
                writes += 1
                return created
            }
            GoogleTasksClient.fetch = { _ in throw StoreTestError.fetchFailed }
            // An existing directory cannot be replaced by an atomic JSON file
            // write. This fails deterministically even under a privileged test
            // runner, and touches only the explicitly isolated fixture path.
            let previousCache = try Data(contentsOf: AppPaths.snapshot)
            try FileManager.default.removeItem(at: AppPaths.snapshot)
            try FileManager.default.createDirectory(at: AppPaths.snapshot, withIntermediateDirectories: false)
            defer {
                try? FileManager.default.removeItem(at: AppPaths.snapshot)
                try? previousCache.write(to: AppPaths.snapshot, options: .atomic)
            }
            let succeeded = await store.addTask(title: created.title, list: list)
            expect(succeeded, "A confirmed Google insertion was reported as failed because its offline cache could not be saved")
            expect(!store.isMutating && store.lists[0].tasks.filter { $0.id == created.id }.count == 1,
                   "Cache failure lost the confirmed task or left submission controls busy")
            expect(writes == 1, "Cache failure retried a confirmed Google insertion")
            expect(store.error?.contains("Saved to Google") == true && store.error?.contains("offline copy") == true,
                   "Cache failure did not distinguish confirmed remote success from local persistence failure")
            print("PASS: confirmed insertion returns success despite local cache failure, retains the task, and never resubmits it")
        }
        do {
            let store = try await loadedStore()
            store.oauth.hasWriteAccess = true
            GoogleTasksClient.write = { _, _, _ in throw StoreTestError.fetchFailed }
            let failed = await store.updateTask(task: list.tasks[0], list: list, title: "Synthetic failed edit", notes: "", due: nil)
            expect(!failed && store.lists == accountALists && !store.isMutating, "A failed write changed state or stayed busy")
            expect(store.error?.contains("Refresh before trying again") == true, "An uncertain result did not advise reconciliation")
            print("PASS: failed writes preserve tasks and report an uncertain outcome without retrying")
        }
        do {
            let store = try await loadedStore()
            store.oauth.hasWriteAccess = true
            var serverLists = accountALists
            var operations: [String] = []
            GoogleTasksClient.fetch = { _ in serverLists }
            GoogleTasksClient.write = { action, listID, taskID in
                expect(listID == list.id && taskID == list.tasks[0].id, "Mutation targeted a different task")
                operations.append(action)
                let saved = GoogleTask(id: taskID!, title: "Synthetic edited task", notes: "Synthetic edited notes",
                                       due: "2026-10-15T00:00:00Z", status: action == "complete" ? "completed" : "needsAction", parent: nil)
                serverLists[0].tasks = [saved]
                return saved
            }
            let edited = await store.updateTask(task: list.tasks[0], list: list, title: "Synthetic edited task", notes: "Synthetic edited notes", due: Date())
            expect(edited, "Confirmed edit failed")
            try await waitUntil("Edit refresh did not settle") { !store.isLoading }
            let completed = await store.toggleCompletion(task: store.lists[0].tasks[0], list: list)
            expect(completed && store.lists[0].tasks[0].isCompleted, "Confirmed completion failed")
            expect(store.status == "1 list · 0 tasks", "Completed tasks were counted as remaining")
            try await waitUntil("Completion refresh did not settle") { !store.isLoading }
            let reopened = await store.toggleCompletion(task: store.lists[0].tasks[0], list: list)
            expect(reopened && !store.lists[0].tasks[0].isCompleted, "Confirmed reopening failed")
            try await waitUntil("Reopen refresh did not settle") { !store.isLoading }
            GoogleTasksClient.remove = { listID, taskID in
                expect(listID == list.id && taskID == list.tasks[0].id, "Delete targeted a different task")
                operations.append("delete")
                serverLists[0].tasks = []
            }
            let deleted = await store.deleteTask(task: store.lists[0].tasks[0], list: list)
            expect(deleted && store.lists[0].tasks.isEmpty, "Confirmed deletion remained visible")
            try await waitUntil("Delete refresh did not settle") { !store.isLoading }
            expect(operations == ["update", "complete", "reopen", "delete"], "Unexpected or repeated task mutation")
            print("PASS: edit, complete, reopen, and delete reconcile confirmed results and remaining counts")
        }
        do {
            let store = try await loadedStore()
            store.oauth.hasWriteAccess = true
            let parent = list.tasks[0]
            let child = GoogleTask(id: "synthetic-child", title: "Synthetic dependent task", notes: nil,
                                   due: nil, status: "needsAction", parent: parent.id)
            let completedChild = GoogleTask(id: "synthetic-completed-child", title: "Synthetic completed dependent", notes: nil,
                                            due: nil, status: "completed", parent: parent.id)
            let unrelated = GoogleTask(id: "synthetic-unrelated", title: "Synthetic unrelated task", notes: nil,
                                       due: nil, status: "needsAction", parent: nil)
            let unrelatedChild = GoogleTask(id: "synthetic-unrelated-child", title: "Synthetic unrelated dependent", notes: nil,
                                            due: nil, status: "needsAction", parent: unrelated.id)
            let seeded = TaskList(id: list.id, title: list.title,
                                  tasks: [parent, child, completedChild, unrelated, unrelatedChild])
            try await refresh(store, lists: [seeded])
            var deletes = 0
            GoogleTasksClient.remove = { listID, taskID in
                expect(listID == list.id && taskID == parent.id, "Parent deletion targeted another record")
                deletes += 1
            }
            GoogleTasksClient.fetch = { _ in throw StoreTestError.fetchFailed }
            let deleted = await store.deleteTask(task: parent, list: seeded)
            expect(deleted, "Confirmed parent deletion was reported as failed")
            try await waitUntil("Failed parent-deletion reconciliation did not settle") { !store.isLoading }
            let remaining = [unrelated, unrelatedChild]
            expect(store.lists[0].tasks == remaining, "Confirmed deletion left dependent rows visible or removed unrelated rows")
            expect(store.status == "1 list · 2 tasks", "Dependent rows remained in the visible task count")
            let cached = try JSONDecoder().decode(TaskSnapshot.self, from: Data(contentsOf: AppPaths.snapshot))
            expect(cached.lists[0].tasks == remaining, "Dependent rows remained in the offline cache after reconciliation failed")
            expect(deletes == 1 && store.connectionState == "Offline", "A failed reconciliation retried deletion or claimed live data")
            let staleChildWrite = await store.updateTask(task: child, list: seeded, title: child.title, notes: "", due: nil)
            expect(!staleChildWrite, "A dependent row hidden after parent deletion remained writable")

            // The subsequent successful read remains authoritative. The test
            // intentionally makes no claim about Google's cascade semantics.
            let survivingChild = GoogleTask(id: child.id, title: child.title, notes: nil,
                                            due: nil, status: "needsAction", parent: nil)
            let reconciled = TaskList(id: list.id, title: list.title, tasks: remaining + [survivingChild])
            try await refresh(store, lists: [reconciled])
            expect(store.lists == [reconciled], "A later authoritative read could not restore a surviving dependent task")
            print("PASS: parent deletion hides dependent rows through read failure, preserves unrelated tasks, and yields to later authoritative data")
        }
        do {
            let store = try await loadedStore()
            store.oauth.hasWriteAccess = true
            var oldRead: CheckedContinuation<[TaskList], Never>?
            var readCount = 0
            var serverLists = accountALists
            GoogleTasksClient.fetch = { _ in
                readCount += 1
                if readCount == 1 { return await withCheckedContinuation { oldRead = $0 } }
                return serverLists
            }
            store.refresh()
            try await waitUntil("Old read did not start") { oldRead != nil }
            GoogleTasksClient.write = { _, _, _ in serverLists[0].tasks.insert(created, at: 0); return created }
            let added = await store.addTask(title: created.title, list: list)
            expect(added, "Create during refresh failed")
            try await waitUntil("New read did not settle") { !store.isLoading }
            oldRead?.resume(returning: accountALists)
            await Task.yield()
            expect(store.lists[0].tasks.contains(created), "A stale in-flight read overwrote a successful write")
            print("PASS: a read started before a write cannot restore stale tasks afterwards")
        }
        do {
            let store = try await loadedStore()
            store.oauth.hasWriteAccess = true
            var response: CheckedContinuation<GoogleTask, Never>?
            GoogleTasksClient.write = { _, _, _ in await withCheckedContinuation { response = $0 } }
            let pending = Task { await store.addTask(title: created.title, list: list) }
            try await waitUntil("Disconnect write did not start") { response != nil }
            store.disconnect()
            expect(!store.isMutating, "Disconnect left mutation controls busy")
            response?.resume(returning: created)
            let disconnectedResult = await pending.value
            expect(!disconnectedResult, "A stale write succeeded after disconnect")
            expectCleared(store)
            print("PASS: a late write response cannot repopulate a disconnected account")
        }
        do {
            let store = try await loadedStore()
            GoogleTasksClient.fetch = { _ in [TaskList(id: "synthetic-other-account-list", title: "Synthetic other account", tasks: [])] }
            store.enableEditing()
            expect(store.lists.isEmpty && !FileManager.default.fileExists(atPath: AppPaths.snapshot.path), "Permission upgrade retained previous account data during sign-in")
            expect(store.selectedListIDs == [list.id], "Permission upgrade discarded the selected list")
            try await waitUntil("Permission upgrade did not finish") { store.canEdit && !store.isLoading && store.connectionState == "Live" }
            expect(store.visibleLists.isEmpty && store.selectedListIDs == [list.id], "A different account expanded the preserved selection")
            print("PASS: editing upgrade preserves the whitelist while clearing previous-account data before sign-in")
        }
        do {
            let store = try await loadedStore()
            store.oauth.signInFails = true
            GoogleTasksClient.fetch = { _ in accountALists }
            store.enableEditing()
            try await waitUntil("Failed upgrade did not restore the readable account") { store.lists == accountALists && !store.isLoading }
            expect(!store.canEdit && store.oauth.isSignedIn, "Denied upgrade changed existing readonly credentials")
            expect(store.error != nil && store.selectedListIDs == [list.id], "Upgrade failure lost its explanation or selection")
            print("PASS: a failed editing upgrade restores the existing readonly view and retains the failure message")
        }
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
        try await mutationTests()

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
