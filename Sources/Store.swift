import Foundation
import Combine

@MainActor
final class TaskStore: ObservableObject {
    @Published var lists: [TaskList] = []
    @Published var isLoading = false
    @Published var status = "Connect your Google Tasks"
    @Published var lastSynced: Date?
    @Published var connectionState = "Snapshot"
    @Published var error: String?
    @Published var searchText = ""
    // A missing preference shows all lists. An explicit empty set shows none;
    // explicit IDs keep newly discovered lists hidden until selected.
    @Published private(set) var selectedListIDs: Set<String>?
    @Published private(set) var isMutating = false
    let oauth = GoogleOAuth()
    var canEdit: Bool { oauth.isSignedIn && oauth.hasWriteAccess && !oauth.isAuthorizing }
    var needsEditingAuthorization: Bool { !canEdit }
    var isAuthorizing: Bool { oauth.isAuthorizing }
    var onConnection: (() -> Void)?
    private let defaults: UserDefaults
    private static let selectionPreference = "FloatTasks.selectedListIDs"
    private lazy var client = GoogleTasksClient(oauth: oauth)
    private var timer: Timer?
    private var syncTask: Task<Void, Never>?
    private var mutationTask: Task<TaskChange, Error>?
    private var oauthObserver: AnyCancellable?
    private var generation = 0

    private enum TaskChange { case saved(GoogleTask), deleted(String) }

    var visibleLists: [TaskList] {
        guard let selectedListIDs else { return lists }
        return lists.filter { selectedListIDs.contains($0.id) }
    }

    var filteredLists: [TaskList] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = visibleLists
        guard !query.isEmpty else { return visible }
        return visible.compactMap { list in
            if list.title.localizedCaseInsensitiveContains(query) { return list }
            var copy = list
            copy.tasks = list.tasks.filter { $0.title.localizedCaseInsensitiveContains(query)
                || ($0.notes?.localizedCaseInsensitiveContains(query) ?? false) }
            return copy.tasks.isEmpty ? nil : copy
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedListIDs = defaults.stringArray(forKey: Self.selectionPreference).map(Set.init)
        oauthObserver = oauth.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        loadCache()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded() }
        }
        Task { @MainActor [weak self] in self?.refreshIfNeeded() }
    }

    func isListVisible(id: String) -> Bool {
        selectedListIDs?.contains(id) ?? true
    }

    func setListVisible(id: String, visible: Bool) {
        // Keeping the default "all" mode when nothing is deselected preserves
        // its behavior for future API lists.
        if selectedListIDs == nil && visible { return }
        var updated = selectedListIDs ?? Set(lists.map(\.id))
        if visible { updated.insert(id) } else { updated.remove(id) }
        applySelectedListIDs(updated)
    }

    func applySelectedListIDs(_ ids: Set<String>) {
        selectedListIDs = ids
        defaults.set(ids.sorted(), forKey: Self.selectionPreference)
        updateCount()
    }

    func showAllLists() {
        resetListSelection()
        updateCount()
    }

    func hideAllLists() { applySelectedListIDs([]) }

    private func resetListSelection() {
        selectedListIDs = nil
        defaults.removeObject(forKey: Self.selectionPreference)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: AppPaths.snapshot), data.count <= 64 * 1024 * 1024,
              let snapshot = try? JSONDecoder().decode(TaskSnapshot.self, from: data),
              (try? AppPaths.validate(snapshot)) != nil else { return }
        lists = snapshot.lists
        lastSynced = AppPaths.date(snapshot.capturedAt)
        connectionState = oauth.isSignedIn ? "Offline" : "Snapshot"
        updateCount()
    }
    private func updateCount() {
        let visible = visibleLists
        let taskCount = visible.reduce(0) { $0 + $1.tasks.filter { !$0.isCompleted }.count }
        status = "\(visible.count) \(visible.count == 1 ? "list" : "lists") · \(taskCount) \(taskCount == 1 ? "task" : "tasks")"
    }
    func refreshIfNeeded() {
        guard oauth.isSignedIn, !isLoading, !isMutating, !oauth.isAuthorizing else { return }
        if connectionState != "Live" || lastSynced == nil || Date().timeIntervalSince(lastSynced!) > 45 { refresh() }
    }
    func refresh() {
        startRefresh(retainingError: nil)
    }
    private func startRefresh(retainingError: String?) {
        guard oauth.isSignedIn else { showConnection(); return }
        guard !isLoading, !isMutating, !oauth.isAuthorizing else { return }
        isLoading = true
        let currentGeneration = generation
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == currentGeneration { self.isLoading = false } }
            do {
                let updated = try await self.client.fetchLists()
                try Task.checkCancellation()
                guard self.generation == currentGeneration else { return }
                let now = ISO8601DateFormatter().string(from: Date())
                let snapshot = TaskSnapshot(version: 1, source: "google_api", capturedAt: now,
                                            sourceURL: "https://tasks.google.com/tasks/", lists: updated, receivedAt: now)
                try AppPaths.save(snapshot)
                if self.lists != updated { self.lists = updated }
                self.lastSynced = Date()
                self.connectionState = "Live"
                self.error = retainingError
                self.updateCount()
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == currentGeneration else { return }
                self.error = retainingError ?? error.localizedDescription
                self.connectionState = "Offline"
            }
        }
    }
    func connect() {
        guard !oauth.isAuthorizing else { return }
        error = nil
        // A new browser authorization may select a different account. Clear
        // the previous view before authorizing so a failed first sync cannot
        // show one account's tasks under another account's connection.
        do { try clearCachedTasks() }
        catch { self.error = "Could not clear the previous task cache. Sign-in was not started."; return }
        Task { @MainActor in
            do { try await oauth.signIn(); refresh() }
            catch {
                let message = error.localizedDescription
                self.error = message
                if oauth.isSignedIn { startRefresh(retainingError: message) }
            }
        }
    }
    func importClient(from url: URL) throws {
        let previousClientID = oauth.configuredClientID
        try oauth.importClient(from: url)
        if previousClientID != oauth.configuredClientID { try clearCachedTasks() }
    }
    // An editing upgrade keeps the local whitelist but removes cached content
    // before browser sign-in, which may select a different Google account.
    func enableEditing() {
        guard !oauth.isAuthorizing, !isMutating else { return }
        error = nil
        do { try clearCachedTasks(resetSelection: false) }
        catch { self.error = "Could not clear the previous task cache. Authorization was not started."; return }
        Task { @MainActor in
            do { try await oauth.signIn(); refresh() }
            catch {
                let message = error.localizedDescription
                self.error = message
                if oauth.isSignedIn { startRefresh(retainingError: message) }
            }
        }
    }

    private func clearCachedTasks(resetSelection: Bool = true) throws {
        generation += 1
        syncTask?.cancel()
        syncTask = nil
        mutationTask?.cancel()
        mutationTask = nil
        isMutating = false
        isLoading = false
        lists = []
        if resetSelection { resetListSelection() }
        lastSynced = nil
        connectionState = "Not connected"
        status = "Connect your Google Tasks"
        if FileManager.default.fileExists(atPath: AppPaths.snapshot.path) {
            try FileManager.default.removeItem(at: AppPaths.snapshot)
        }
    }
    func disconnect() {
        generation += 1
        syncTask?.cancel()
        syncTask = nil
        mutationTask?.cancel()
        mutationTask = nil
        isMutating = false
        isLoading = false
        do {
            try oauth.signOut()
            try clearCachedTasks()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func showConnection() { onConnection?() }

    func addTask(title: String, list: TaskList) async -> Bool {
        await performChange(listID: list.id) {
            .saved(try await self.client.createTask(listID: list.id, title: title))
        }
    }

    func updateTask(task: GoogleTask, list: TaskList, title: String, notes: String, due: Date?) async -> Bool {
        await performChange(listID: list.id, taskID: task.id) {
            .saved(try await self.client.updateTask(listID: list.id, taskID: task.id,
                                                   title: title, notes: notes.isEmpty ? nil : notes, due: due))
        }
    }

    func toggleCompletion(task: GoogleTask, list: TaskList) async -> Bool {
        await performChange(listID: list.id, taskID: task.id) {
            .saved(try await self.client.setCompleted(listID: list.id, taskID: task.id, completed: !task.isCompleted))
        }
    }

    func deleteTask(task: GoogleTask, list: TaskList) async -> Bool {
        await performChange(listID: list.id, taskID: task.id) {
            try await self.client.deleteTask(listID: list.id, taskID: task.id)
            return .deleted(task.id)
        }
    }

    private func performChange(listID: String, taskID: String? = nil,
                               operation: @escaping @MainActor () async throws -> TaskChange) async -> Bool {
        guard canEdit else {
            error = "Enable editing to allow changes to Google Tasks."
            return false
        }
        guard !isMutating else { return false }
        guard isListVisible(id: listID), let list = lists.first(where: { $0.id == listID }),
              taskID == nil || list.tasks.contains(where: { $0.id == taskID }) else {
            error = "This task or list is no longer available in the panel. Refresh and try again."
            return false
        }
        // Invalidate a read already in flight so it cannot replace the result of
        // a later write with its earlier snapshot. Only one write runs at a time.
        generation += 1
        let currentGeneration = generation
        syncTask?.cancel()
        syncTask = nil
        isLoading = false
        isMutating = true
        error = nil
        let pending = Task { @MainActor in try await operation() }
        mutationTask = pending
        defer {
            if generation == currentGeneration {
                mutationTask = nil
                isMutating = false
            }
        }
        do {
            let change = try await pending.value
            try Task.checkCancellation()
            guard generation == currentGeneration,
                  let index = lists.firstIndex(where: { $0.id == listID }) else { return false }
            switch change {
            case .saved(let saved):
                if let taskIndex = lists[index].tasks.firstIndex(where: { $0.id == saved.id }) {
                    lists[index].tasks[taskIndex] = saved
                } else {
                    lists[index].tasks.insert(saved, at: 0)
                }
            case .deleted(let id):
                // Hide dependent rows until the follow-up read reconciles
                // them, rather than leaving orphaned cached rows editable.
                let children = Dictionary(grouping: lists[index].tasks.compactMap { task in
                    task.parent.map { (parent: $0, id: task.id) }
                }, by: \.parent)
                var pendingIDs = [id]
                var removed = Set<String>()
                while let next = pendingIDs.popLast() {
                    guard removed.insert(next).inserted else { continue }
                    pendingIDs.append(contentsOf: (children[next] ?? []).map(\.id))
                }
                lists[index].tasks.removeAll { removed.contains($0.id) }
            }
            updateCount()
            connectionState = "Live"
            let now = ISO8601DateFormatter().string(from: Date())
            do {
                try AppPaths.save(TaskSnapshot(version: 1, source: "google_api", capturedAt: now,
                                               sourceURL: "https://tasks.google.com/tasks/", lists: lists, receivedAt: now))
            } catch {
                self.error = "Saved to Google, but the offline copy could not be updated. Refresh to try saving it again."
                return true
            }
            // The write is already confirmed. A subsequent read failure must
            // never make the UI resubmit a successful insertion.
            isMutating = false
            refresh()
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == currentGeneration else { return false }
            self.error = "Could not confirm the change. \(error.localizedDescription) Refresh before trying again."
            return false
        }
    }
}
