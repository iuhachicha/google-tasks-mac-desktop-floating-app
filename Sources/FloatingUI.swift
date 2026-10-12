import AppKit
import SwiftUI

/// A deliberately narrow, vertically stacked view. The enclosing NSWindow must
/// be non-opaque with a clear background so only the material cards are visible.
struct RootView: View {
    @ObservedObject var store: TaskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onPin: () -> Void
    let onHide: () -> Void
    let onSettings: () -> Void
    let isPinned: Bool

    @State private var showsSearch = false
    @State private var collapsedLists: Set<String> = []
    @FocusState private var isSearchFocused: Bool
    private static let collapsedListsPreference = "FloatTasks.collapsedListIDs"

    var body: some View {
        VStack(spacing: 8) {
            header

            if !store.canEdit && !store.visibleLists.isEmpty {
                VStack(spacing: 6) {
                    Button(store.isAuthorizing ? "Waiting for Google…" : "Enable editing") {
                        store.enableEditing()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.isAuthorizing || store.isMutating)
                    Text("Add, edit, and complete tasks here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .floatingCard(radius: 18)
            }

            if showsSearch {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Find a task…", text: $store.searchText)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .focused($isSearchFocused)
                        .accessibilityLabel("Search Tasks")
                        .disabled(store.isMutating)
                    if !store.searchText.isEmpty {
                        Button {
                            store.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(QuietButtonStyle())
                        .help("Clear search")
                        .accessibilityLabel("Clear Search")
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .floatingCard(radius: 16)
            }

            if store.visibleLists.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    emptyState
                        .padding(.vertical, 5)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    // Measure every list card up front so its variable height
                    // cannot trigger repeated scroll-offset corrections at the bottom.
                    VStack(spacing: 10) {
                        if store.filteredLists.isEmpty {
                            Text("No matching tasks")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(24)
                                .floatingCard(radius: 22)
                        }
                        ForEach(store.filteredLists) { list in
                            TaskListCard(
                                store: store,
                                list: list,
                                isCollapsed: collapsedLists.contains(list.id),
                                toggleCollapsed: {
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                                        if collapsedLists.contains(list.id) {
                                            collapsedLists.remove(list.id)
                                        } else {
                                            collapsedLists.insert(list.id)
                                        }
                                        UserDefaults.standard.set(Array(collapsedLists).sorted(), forKey: Self.collapsedListsPreference)
                                    }
                                }
                            )
                        }
                    }
                    // Room for the soft edges of the cards inside the scroll view.
                    .padding(.horizontal, 4)
                    .padding(.vertical, 5)
                }
                .padding(.horizontal, -4)
            }

            if let error = store.error, !error.isEmpty, !store.visibleLists.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .floatingCard(radius: 14)
                .help(error)
            }

            footer
        }
        .padding(12)
        .frame(minWidth: 240, idealWidth: 280, maxWidth: .infinity,
               minHeight: 320, idealHeight: 620, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            collapsedLists = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedListsPreference) ?? [])
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Float Tasks")
                .font(.caption.weight(.medium))
            Spacer(minLength: 8)
            if store.isLoading || store.isMutating {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(store.isMutating ? "Saving Changes" : "Refreshing Tasks")
            }
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.medium))
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .floatingCard(radius: 15)
        .overlay(WindowDragArea())
        .help("Drag to move • Resize from an edge")
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            Spacer(minLength: 6)
            Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text(emptyStateTitle)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(emptyStateDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            if !store.isLoading {
                Button(hasConnectedEmptyState || hasHiddenLists ? "Connection and settings" : "Connect Google Tasks") {
                    store.showConnection()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.accentColor)
                if let error = store.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(error)
                }
            }
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .floatingCard(radius: 25)
    }

    private var hasConnectedEmptyState: Bool {
        store.connectionState == "Live" && store.lists.isEmpty
    }

    private var hasHiddenLists: Bool {
        !store.lists.isEmpty && store.visibleLists.isEmpty
    }

    private var emptyStateTitle: String {
        if store.isLoading { return "Getting your tasks…" }
        if hasHiddenLists { return "No selected lists available" }
        return hasConnectedEmptyState ? "No task lists yet" : "A little room for your tasks"
    }

    private var emptyStateDescription: String {
        if store.isLoading { return "Your lists will appear here." }
        if hasHiddenLists { return "Your saved list selection is empty\nor no longer available." }
        return hasConnectedEmptyState ? "Your connected account has\nno task lists available." : "Your Google Tasks lists,\none below the other."
    }

    private var footer: some View {
        HStack(spacing: 2) {
            footerButton("magnifyingglass", help: "Search tasks", isActive: showsSearch) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    showsSearch.toggle()
                    if !showsSearch { store.searchText = "" }
                }
                isSearchFocused = showsSearch
            }
            .accessibilityValue(showsSearch ? "Shown" : "Hidden")
            footerButton("arrow.clockwise", help: "Refresh tasks") {
                store.refresh()
            }
            .disabled(store.isLoading || store.isMutating)
            footerButton(isPinned ? "pin.fill" : "pin", help: isPinned ? "Dismiss when clicking outside" : "Keep panel open", isActive: isPinned, action: onPin)
                .accessibilityLabel("Keep Panel Open")
                .accessibilityValue(isPinned ? "On" : "Off")
            footerDivider
            Button(action: onSettings) {
                HStack(spacing: 5) {
                    Image(systemName: store.connectionState == "Live" ? "checkmark.circle.fill" : "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(store.connectionState == "Live" ? Color.green : Color(nsColor: .secondaryLabelColor))
                        .accessibilityHidden(true)
                    Text(connectionLabel)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .help(connectionHelp)
            .accessibilityLabel("Connection and Settings")
            .accessibilityValue(store.connectionState)
            footerButton("xmark", help: "Close panel (reopen from the menu bar)", action: onHide)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .floatingCard(radius: 21)
        .fixedSize()
    }

    private var connectionLabel: String {
        switch store.connectionState {
        case "Snapshot": return "Saved"
        case "Not connected": return "Connect"
        default: return store.connectionState
        }
    }

    private var connectionHelp: String {
        let explanation: String
        switch store.connectionState {
        case "Snapshot":
            explanation = "Saved tasks. Sign in to Google for live updates."
        case "Offline":
            explanation = "Last saved view. Check your connection or sign in again."
        case "Live":
            explanation = "Connected directly to Google Tasks."
        default:
            explanation = "Sign in to Google to show your task lists."
        }
        if let lastSynced = store.lastSynced {
            return explanation + "\nLast synced " + lastSynced.formatted(date: .abbreviated, time: .shortened) + ". Click for connection settings."
        }
        return explanation + " Click for connection settings."
    }

    private var footerDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    private func footerButton(_ symbol: String, help: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color(nsColor: .secondaryLabelColor))
                .frame(width: 28, height: 28)
                .background(isActive ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct TaskListCard: View {
    @ObservedObject var store: TaskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let list: TaskList
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    @State private var showsCompleted = false
    @State private var isAdding = false
    @State private var isSubmitting = false
    @State private var newTaskTitle = ""
    @FocusState private var isAddFocused: Bool

    private var activeTasks: [GoogleTask] { list.tasks.filter { !$0.isCompleted } }
    private var completedTasks: [GoogleTask] { list.tasks.filter(\.isCompleted) }
    private var isBusy: Bool { store.isMutating || isSubmitting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleCollapsed) {
                HStack(spacing: 8) {
                    Text(list.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    Text("\(activeTasks.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 11, height: 11)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle(cornerRadius: 18))
            .help(isCollapsed ? "Expand \(list.title)" : "Collapse \(list.title)")
            .accessibilityLabel(list.title)
            .accessibilityValue("\(isCollapsed ? "Collapsed" : "Expanded"), \(activeTasks.count) remaining tasks")

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    if store.canEdit {
                        quickAdd
                    }

                    ForEach(activeTasks) { task in
                        TaskRow(store: store, task: task, list: list)
                    }

                    if activeTasks.isEmpty {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                            Text("All clear")
                                .font(.body)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 9)
                    }

                    if !completedTasks.isEmpty {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                                showsCompleted.toggle()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .rotationEffect(.degrees(showsCompleted ? 90 : 0))
                                    .accessibilityHidden(true)
                                Text("Completed · \(completedTasks.count)")
                                    .font(.caption)
                            }
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityLabel("Completed Tasks")
                        .accessibilityValue("\(completedTasks.count), \(showsCompleted ? "Expanded" : "Collapsed")")
                        .accessibilityHint(showsCompleted ? "Hide completed tasks" : "Show completed tasks to edit or reopen them")
                        if showsCompleted {
                            ForEach(completedTasks) { task in
                                TaskRow(store: store, task: task, list: list)
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingCard(radius: 23)
    }

    @ViewBuilder
    private var quickAdd: some View {
        if isAdding {
            VStack(alignment: .leading, spacing: 8) {
                TextField("New task", text: $newTaskTitle, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused($isAddFocused)
                    .onSubmit(addTask)
                    .disabled(isBusy)
                    .accessibilityLabel("New task title")
                HStack(spacing: 8) {
                    Button(isSubmitting ? "Adding…" : "Add", action: addTask)
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") {
                        newTaskTitle = ""
                        isAdding = false
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } else {
            Button {
                isAdding = true
                isAddFocused = true
            } label: {
                Label("Add Task", systemImage: "plus")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(isBusy)
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
        }
    }

    private func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, store.canEdit, !isBusy else { return }
        isSubmitting = true
        Task {
            let succeeded = await store.addTask(title: title, list: list)
            isSubmitting = false
            if succeeded {
                newTaskTitle = ""
                isAdding = false
            }
        }
    }
}

private struct TaskRow: View {
    @ObservedObject var store: TaskStore
    let task: GoogleTask
    let list: TaskList
    @State private var isEditing = false
    @State private var isSubmitting = false
    @State private var confirmsDelete = false
    @State private var draftTitle = ""
    @State private var draftNotes = ""
    @State private var hasDueDate = false
    @State private var draftDueDate = Date()
    @FocusState private var isTitleFocused: Bool

    private var isBusy: Bool { store.isMutating || isSubmitting }
    private var validTitle: Bool { !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var accessibleDetails: String {
        [task.isCompleted ? "Completed" : "Incomplete",
         TaskDueDate.label(task.due).map { "Due \($0)" }, task.notes]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditing {
                editor
            } else {
                summary
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 7) {
            if store.canEdit {
                Button(action: toggleCompletion) {
                    completionIcon
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(isBusy)
                .help(task.isCompleted ? "Reopen task" : "Complete task")
                .accessibilityLabel(task.isCompleted ? "Reopen \(task.title)" : "Complete \(task.title)")
            } else {
                completionIcon
                    .accessibilityLabel(task.isCompleted ? "Completed" : "Incomplete")
            }

            Button(action: beginEditing) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title.isEmpty ? "Untitled task" : task.title)
                        .font(.body)
                        .foregroundStyle(Color(nsColor: task.isCompleted ? .secondaryLabelColor : .labelColor))
                        .multilineTextAlignment(.leading)
                        .strikethrough(task.isCompleted, color: .secondary.opacity(0.45))
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                    if let notes = task.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !task.isCompleted {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .lineLimit(1)
                    }
                    if let due = TaskDueDate.label(task.due), !task.isCompleted {
                        Label(due, systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .padding(.top, 1)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle(cornerRadius: 6))
            .disabled(!store.canEdit || isBusy)
            .help(store.canEdit ? "Edit task" : "Enable editing to change this task")
            .accessibilityLabel(task.title.isEmpty ? "Untitled Task" : task.title)
            .accessibilityValue(accessibleDetails)
            .accessibilityHint(store.canEdit ? "Edit the title, notes, and due date" : "Enable editing to change this task")
            .padding(.top, 5)
        }
        .padding(.leading, task.parent == nil ? 12 : 26)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .help([task.title, task.notes].compactMap { $0 }.joined(separator: "\n\n"))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Task")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Task title", text: $draftTitle, axis: .vertical)
                .font(.body.weight(.medium))
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($isTitleFocused)
                .onSubmit(saveTask)
                .disabled(isBusy || confirmsDelete)
                .accessibilityLabel("Task title")
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $draftNotes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 66)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(isBusy || confirmsDelete)
                    .accessibilityLabel("Task notes")
            }
            VStack(alignment: .leading, spacing: 7) {
                Toggle("Due Date", isOn: $hasDueDate)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                if hasDueDate {
                    DatePicker("", selection: $draftDueDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .controlSize(.small)
                        .accessibilityLabel("Task due date")
                }
            }
            .disabled(isBusy || confirmsDelete)

            if confirmsDelete {
                deleteConfirmation
            } else {
                HStack(spacing: 7) {
                    Button(isSubmitting ? "Saving…" : "Save", action: saveTask)
                        .buttonStyle(.borderedProminent)
                        .disabled(!validTitle || isBusy || !store.canEdit)
                    Button("Cancel", action: cancelEditing)
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                    Spacer(minLength: 0)
                    Button {
                        confirmsDelete = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(QuietButtonStyle())
                    .help("Delete task…")
                    .accessibilityLabel("Delete task")
                    .disabled(isBusy || !store.canEdit)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete this task?")
                .font(.caption.weight(.semibold))
            Text("Subtasks may also be removed. Assigned tasks are removed from their original Docs or Chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(isSubmitting ? "Deleting…" : "Delete", role: .destructive, action: deleteTask)
                    .buttonStyle(.bordered)
                    .disabled(isBusy || !store.canEdit)
                Button("Cancel") { confirmsDelete = false }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
            }
            .controlSize(.small)
        }
    }

    private var completionIcon: some View {
        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(task.isCompleted ? Color.green : Color(nsColor: .controlTextColor))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }

    private func beginEditing() {
        guard store.canEdit, !isBusy else { return }
        draftTitle = task.title
        draftNotes = task.notes ?? ""
        let due = TaskDueDate.parse(task.due)
        hasDueDate = due != nil
        draftDueDate = due ?? Date()
        confirmsDelete = false
        isEditing = true
        isTitleFocused = true
    }

    private func cancelEditing() {
        guard !isBusy else { return }
        isEditing = false
        confirmsDelete = false
    }

    private func saveTask() {
        guard validTitle, store.canEdit, !isBusy, !confirmsDelete else { return }
        isSubmitting = true
        Task {
            let succeeded = await store.updateTask(task: task, list: list,
                title: draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: draftNotes, due: hasDueDate ? draftDueDate : nil)
            isSubmitting = false
            if succeeded { isEditing = false }
        }
    }

    private func toggleCompletion() {
        guard store.canEdit, !isBusy else { return }
        isSubmitting = true
        Task {
            _ = await store.toggleCompletion(task: task, list: list)
            isSubmitting = false
        }
    }

    private func deleteTask() {
        guard confirmsDelete, store.canEdit, !isBusy else { return }
        isSubmitting = true
        Task {
            let succeeded = await store.deleteTask(task: task, list: list)
            isSubmitting = false
            if succeeded {
                confirmsDelete = false
                isEditing = false
            }
        }
    }
}

private enum TaskDueDate {
    // Google Tasks due values carry a calendar date, not a local alarm time.
    static func parse(_ value: String?) -> Date? {
        guard let value, value.count >= 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }

    static func label(_ value: String?) -> String? {
        guard let date = parse(value) else { return nil }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date()) ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

private struct FloatingCard: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.regularMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1.5 : 0.5)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Color(nsColor: .shadowColor).opacity(0.08), radius: 8, x: 0, y: 3)
    }
}

private extension View {
    func floatingCard(radius: CGFloat) -> some View {
        modifier(FloatingCard(radius: radius))
    }
}

private struct QuietButtonStyle: PrimitiveButtonStyle {
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        HoverButton(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct HoverButton: View {
        let configuration: PrimitiveButtonStyleConfiguration
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            // The native borderless button retains macOS press and keyboard
            // focus behavior; the only custom feedback is its quiet hover fill.
            Button(configuration)
                .buttonStyle(.borderless)
                .background {
                    if isHovered && isEnabled {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.55))
                    }
                }
                .onHover { isHovered = $0 }
        }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
