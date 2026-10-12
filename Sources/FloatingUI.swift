import AppKit
import SwiftUI

/// A deliberately narrow, vertically stacked view. The enclosing NSWindow must
/// be non-opaque with a clear background so only the material cards are visible.
struct RootView: View {
    @ObservedObject var store: TaskStore
    let onPin: () -> Void
    let onHide: () -> Void
    let onSettings: () -> Void
    let isPinned: Bool

    @State private var showsSearch = false
    @State private var collapsedLists: Set<String> = []
    private static let collapsedListsPreference = "FloatTasks.collapsedListIDs"

    var body: some View {
        VStack(spacing: 9) {
            header

            if showsSearch {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Find a task…", text: $store.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !store.searchText.isEmpty {
                        Button {
                            store.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .floatingCard(radius: 16)
            }

            if store.lists.isEmpty {
                emptyState
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    // Measure every list card up front so its variable height
                    // cannot trigger repeated scroll-offset corrections at the bottom.
                    VStack(spacing: 10) {
                        if store.filteredLists.isEmpty {
                            Text("No matching tasks")
                                .font(.system(size: 12))
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
                                    withAnimation(.easeInOut(duration: 0.18)) {
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

            if let error = store.error, !error.isEmpty, !store.lists.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).lineLimit(2)
                }
                .font(.system(size: 10))
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
        .frame(minWidth: 240, idealWidth: 308, maxWidth: .infinity,
               minHeight: 320, idealHeight: 620, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            collapsedLists = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedListsPreference) ?? [])
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Tasks")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 8)
            if store.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.8)
            } else if !store.lists.isEmpty {
                Text("\(store.lists.reduce(0) { $0 + $1.tasks.filter { !$0.isCompleted }.count })")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.primary.opacity(0.055), in: Capsule())
                    .accessibilityLabel("Remaining tasks")
            }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .floatingCard(radius: 22)
        .overlay(WindowDragArea())
        .help("Drag to move • Resize from an edge")
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            Spacer(minLength: 6)
            Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text(store.isLoading ? "Getting your tasks…" : (hasConnectedEmptyState ? "No task lists yet" : "A little room for your tasks"))
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                Text(store.isLoading ? "Your lists will appear here." : (hasConnectedEmptyState ? "Create a list in Google Tasks,\nand it will appear here." : "Your Google Tasks lists,\none below the other."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            if !store.isLoading {
                Button(hasConnectedEmptyState ? "Open Google Tasks" : "Connect Google Tasks") {
                    if hasConnectedEmptyState {
                        store.openGoogleTasks()
                    } else {
                        store.showConnection()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.accentColor)
                if let error = store.error, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
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

    private var footer: some View {
        VStack(spacing: 7) {
          HStack(spacing: 0) {
            footerButton("magnifyingglass", help: "Search tasks", isActive: showsSearch) {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showsSearch.toggle()
                    if !showsSearch { store.searchText = "" }
                }
            }
            footerButton("arrow.clockwise", help: "Refresh tasks") {
                store.refresh()
            }
            .disabled(store.isLoading)
            footerDivider
            footerButton(isPinned ? "pin.fill" : "pin", help: isPinned ? "Dismiss when clicking outside" : "Keep panel open", isActive: isPinned, action: onPin)
            footerButton("slider.horizontal.3", help: "Connection and settings", action: onSettings)
            footerDivider
            footerButton("xmark", help: "Close panel (reopen from the menu bar)", action: onHide)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .floatingCard(radius: 24)
          .fixedSize()
          Button(action: onSettings) {
              HStack(spacing: 5) {
                  Circle()
                      .fill(store.connectionState == "Live" ? Color.green.opacity(0.8) : Color.secondary.opacity(0.45))
                      .frame(width: 4, height: 4)
                  Text(store.connectionState)
                      .font(.system(size: 9, weight: .medium))
                      .lineLimit(1)
                      .fixedSize(horizontal: true, vertical: false)
                  if !store.status.isEmpty {
                      Text("· " + store.status)
                          .font(.system(size: 9))
                          .lineLimit(1)
                          .truncationMode(.tail)
                  }
              }
              .foregroundStyle(.secondary)
              .padding(.horizontal, 9)
              .padding(.vertical, 4)
              .floatingCard(radius: 10)
          }
          .buttonStyle(.plain)
          .help(connectionHelp)
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
            .fill(.primary.opacity(0.09))
            .frame(width: 1, height: 19)
            .padding(.horizontal, 3)
    }

    private func footerButton(_ symbol: String, help: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary.opacity(0.78))
                .frame(width: 32, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(QuietIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct TaskListCard: View {
    @ObservedObject var store: TaskStore
    let list: TaskList
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    @State private var showsCompleted = false
    @State private var isAdding = false
    @State private var newTaskTitle = ""
    @FocusState private var isAddFocused: Bool

    private var activeTasks: [GoogleTask] { list.tasks.filter { !$0.isCompleted } }
    private var completedTasks: [GoogleTask] { list.tasks.filter(\.isCompleted) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleCollapsed) {
                HStack(spacing: 8) {
                    Text(list.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    Text("\(activeTasks.count)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 11, height: 11)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand \(list.title)" : "Collapse \(list.title)")
            .accessibilityLabel(list.title)
            .accessibilityValue("\(isCollapsed ? "Collapsed" : "Expanded"), \(activeTasks.count) remaining tasks")

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(activeTasks) { task in
                        TaskRow(task: task, canEdit: store.canEdit, onOpen: { store.openGoogleTasks() }) {
                            store.toggleCompletion(task: task, list: list)
                        }
                    }

                    if activeTasks.isEmpty {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                            Text("All clear")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 9)
                    }

                    if !completedTasks.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                showsCompleted.toggle()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .rotationEffect(.degrees(showsCompleted ? 90 : 0))
                                Text("Completed · \(completedTasks.count)")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showsCompleted {
                            ForEach(completedTasks) { task in
                                TaskRow(task: task, canEdit: store.canEdit, onOpen: { store.openGoogleTasks() }) {
                                    store.toggleCompletion(task: task, list: list)
                                }
                            }
                        }
                    }

                    if store.canEdit {
                        if isAdding {
                            HStack(alignment: .center, spacing: 7) {
                                Image(systemName: "plus")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                TextField("New task", text: $newTaskTitle)
                                    .font(.system(size: 12))
                                    .textFieldStyle(.plain)
                                    .focused($isAddFocused)
                                    .onSubmit(addTask)
                                    .onExitCommand {
                                        newTaskTitle = ""
                                        isAdding = false
                                    }
                                Button(action: addTask) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 17))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .help("Add task")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        } else {
                            Button {
                                isAdding = true
                                isAddFocused = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .medium))
                                    Text("Add task")
                                        .font(.system(size: 11))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingCard(radius: 23)
    }

    private func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        store.addTask(title: title, list: list)
        newTaskTitle = ""
        isAdding = false
    }
}

private struct TaskRow: View {
    let task: GoogleTask
    let canEdit: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if canEdit {
                Button(action: onToggle) {
                    completionIcon
                }
                .buttonStyle(.plain)
                .help(task.isCompleted ? "Mark incomplete" : "Complete task")
                .accessibilityLabel(task.isCompleted ? "Mark \(task.title) incomplete" : "Complete \(task.title)")
            } else {
                completionIcon
                    .accessibilityLabel(task.isCompleted ? "Completed" : "Incomplete")
            }

            Button(action: onOpen) {
              VStack(alignment: .leading, spacing: 3) {
                Text(task.title.isEmpty ? "Untitled task" : task.title)
                    .font(.system(size: 12))
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .strikethrough(task.isCompleted, color: .secondary.opacity(0.45))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                if let notes = task.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !task.isCompleted {
                    Text(notes)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let due = dueLabel, !task.isCompleted {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 8))
                        Text(due)
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in Google Tasks")
            .padding(.top, 1)
            Spacer(minLength: 0)
        }
        .padding(.leading, task.parent == nil ? 15 : 29)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Color.primary.opacity(0.025) : Color.clear)
        .onHover { isHovered = $0 }
        .help([task.title, task.notes].compactMap { $0 }.joined(separator: "\n\n"))
    }

    private var completionIcon: some View {
        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 16, weight: .light))
            .foregroundStyle(task.isCompleted ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(isHovered ? 0.9 : 0.45))
            .frame(width: 18, height: 19)
            .contentShape(Rectangle())
    }

    private var dueLabel: String? {
        guard let due = task.due, due.count >= 10 else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(due.prefix(10))) else { return nil }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date()) ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

private struct FloatingCard: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.055), radius: 8, x: 0, y: 3)
    }
}

private extension View {
    func floatingCard(radius: CGFloat) -> some View {
        modifier(FloatingCard(radius: radius))
    }
}

private struct QuietIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.07) : Color.clear, in: Circle())
            .opacity(configuration.isPressed ? 0.65 : 1)
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
