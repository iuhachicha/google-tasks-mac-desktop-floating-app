import Foundation
import AppKit
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
    let canEdit = false
    let oauth = GoogleOAuth()
    var onConnection: (() -> Void)?
    private let defaults: UserDefaults
    private static let selectionPreference = "FloatTasks.selectedListIDs"
    private lazy var client = GoogleTasksClient(oauth: oauth)
    private var timer: Timer?
    private var syncTask: Task<Void, Never>?
    private var generation = 0

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
        let taskCount = visible.reduce(0) { $0 + $1.tasks.count }
        status = "\(visible.count) \(visible.count == 1 ? "list" : "lists") · \(taskCount) \(taskCount == 1 ? "task" : "tasks")"
    }
    func refreshIfNeeded() {
        guard oauth.isSignedIn, !isLoading else { return }
        if connectionState != "Live" || lastSynced == nil || Date().timeIntervalSince(lastSynced!) > 45 { refresh() }
    }
    func refresh() {
        guard oauth.isSignedIn else { showConnection(); return }
        guard !isLoading else { return }
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
                self.error = nil
                self.updateCount()
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == currentGeneration else { return }
                self.error = error.localizedDescription
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
            catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
        }
    }
    func importClient(from url: URL) throws {
        let previousClientID = oauth.configuredClientID
        try oauth.importClient(from: url)
        if previousClientID != oauth.configuredClientID { try clearCachedTasks() }
    }
    private func clearCachedTasks() throws {
        generation += 1
        syncTask?.cancel()
        syncTask = nil
        isLoading = false
        lists = []
        resetListSelection()
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
        isLoading = false
        do {
            try oauth.signOut()
            try clearCachedTasks()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func showConnection() { onConnection?() }
    func openGoogleTasks() { NSWorkspace.shared.open(URL(string: "https://tasks.google.com/tasks/")!) }
    func toggleCompletion(task: GoogleTask, list: TaskList) { openGoogleTasks() }
    func addTask(title: String, list: TaskList) { openGoogleTasks() }
}
