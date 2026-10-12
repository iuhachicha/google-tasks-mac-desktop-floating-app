import AppKit
import SwiftUI
import Foundation
import Darwin

// Compile with the real FloatingUI.swift and Models.swift. Authentication and
// persistence are deliberately absent from this native layout test executable.
@MainActor
final class TaskStore: ObservableObject {
    @Published var lists: [TaskList]
    @Published var isLoading = false
    @Published var status = "Synthetic layout fixture"
    @Published var lastSynced: Date? = nil
    @Published var connectionState = "Snapshot"
    @Published var error: String? = nil
    @Published var searchText = ""
    let canEdit = true
    let isMutating = false
    let isAuthorizing = false
    let needsEditingAuthorization = false
    var visibleLists: [TaskList] { lists }
    var filteredLists: [TaskList] { lists }

    init() { lists = Self.longLists() }

    static func longLists() -> [TaskList] {
        let sizes = [1, 4, 55, 2, 21, 6, 75, 3]
        return (0..<24).map { i in
            TaskList(id: "list-\(i)", title: "Synthetic list \(i + 1)", tasks: (0..<sizes[i % sizes.count]).map { j in
                GoogleTask(id: "task-\(i)-\(j)",
                           title: j % 3 == 0 ? "Synthetic task \(j + 1) with a longer title that wraps across several lines inside the narrow panel" : "Synthetic task \(j + 1)",
                           notes: j % 4 == 0 ? "Synthetic notes used only to exercise variable row height." : nil,
                           due: j % 5 == 0 ? "2026-10-14T00:00:00.000Z" : nil,
                           status: "needsAction", parent: j % 8 == 0 ? "synthetic-parent" : nil)
            })
        }
    }

    func refresh() {}
    func showConnection() {}
    func enableEditing() { fatalError("Layout tests must not authorize an account") }
    func openGoogleTasks() { fatalError("Layout tests must not open a browser") }
    func toggleCompletion(task: GoogleTask, list: TaskList) async -> Bool { fatalError("Layout tests must not mutate tasks") }
    func addTask(title: String, list: TaskList) async -> Bool { fatalError("Layout tests must not mutate tasks") }
    func updateTask(task: GoogleTask, list: TaskList, title: String, notes: String, due: Date?) async -> Bool { fatalError("Layout tests must not mutate tasks") }
    func deleteTask(task: GoogleTask, list: TaskList) async -> Bool { fatalError("Layout tests must not mutate tasks") }
}

@MainActor
private final class ScrollDriver: ObservableObject {
    @Published var target = ""
    @Published var pulse = 0
    @Published var contentIdentity = 0
}

private struct ScrollTestView: View {
    @ObservedObject var driver: ScrollDriver
    @ObservedObject var store: TaskStore

    var body: some View {
        ScrollViewReader { proxy in
            RootView(store: store, onPin: {}, onHide: {}, onSettings: {}, isPinned: false)
                .id(driver.contentIdentity)
                .onChange(of: driver.pulse) { _ in
                    proxy.scrollTo(driver.target, anchor: driver.target == "list-0" ? .top : .bottom)
                }
        }
    }
}

private final class MainLoopProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var count = 0
    private var isDone = false

    func beat(_ iteration: Int) {
        lock.lock(); defer { lock.unlock() }
        count = iteration
        lastProgress = ProcessInfo.processInfo.systemUptime
    }

    func done() { lock.lock(); isDone = true; lock.unlock() }

    func snapshot() -> (delay: Double, count: Int, done: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (ProcessInfo.processInfo.systemUptime - lastProgress, count, isDone)
    }
}

@MainActor
private final class ScrollTestDelegate: NSObject, NSApplicationDelegate {
    private struct CompactCase {
        let name: String
        let width: CGFloat
        let lists: [TaskList]
        let collapsedIDs: [String]
        let maximumViewportHeight: CGFloat
    }

    private let store = TaskStore()
    private let driver = ScrollDriver()
    private let progress = MainLoopProgress()
    private var panel: NSPanel!
    private var hosting: NSHostingView<ScrollTestView>!
    private var timer: Timer?
    private var iteration = 0
    private let iterations = 96
    private var geometrySamples = 0
    private var topArrivals = 0
    private var bottomArrivals = 0
    private var widths = Set<Int>()
    private var largestOffset: CGFloat = 0
    private var filledLongViewports = 0
    private var compactIndex = 0
    private var settlingTicks = 0
    private var compactChecks = 0
    private var compactFailures: [String] = []
    private var restoringCompact = false
    private var firstTransitionHeight: CGFloat?
    private let originalArgumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    private lazy var compactCases: [CompactCase] = {
        let short = TaskList(id: "compact-short", title: "Short list", tasks: [
            GoogleTask(id: "compact-task", title: "A small task", notes: nil, due: nil, status: "needsAction", parent: nil)
        ])
        let empty = TaskList(id: "compact-empty", title: "Empty list", tasks: [])
        let collapsed = TaskList(id: "compact-collapsed", title: "Collapsed list", tasks: short.tasks)
        var cases: [CompactCase] = []
        for width: CGFloat in [240, 280, 460] {
            cases += [
                CompactCase(name: "short", width: width, lists: [short], collapsedIDs: [], maximumViewportHeight: 260),
                CompactCase(name: "empty list", width: width, lists: [empty], collapsedIDs: [], maximumViewportHeight: 240),
                CompactCase(name: "collapsed", width: width, lists: [collapsed], collapsedIDs: [collapsed.id], maximumViewportHeight: 120),
                CompactCase(name: "empty account", width: width, lists: [], collapsedIDs: [], maximumViewportHeight: 400)
            ]
        }
        // Keep this RootView alive through short -> long -> short updates.
        cases.append(CompactCase(name: "before long", width: 280, lists: [short], collapsedIDs: [], maximumViewportHeight: 260))
        return cases
    }()
    private let startedAt = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Override this key only in this process. No saved user preference is
        // changed, even while checking lists initially restored as collapsed.
        setCollapsedIDs([])
        let leftmostScreen = NSScreen.screens.map(\.frame.minX).min() ?? 0
        panel = NSPanel(contentRect: NSRect(x: leftmostScreen - 800, y: 100, width: 280, height: 640),
                        styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.minSize = NSSize(width: 240, height: 320)
        panel.maxSize = NSSize(width: 460, height: 1400)
        hosting = NSHostingView(rootView: ScrollTestView(driver: driver, store: store))
        // Match the app's frame-owned hosting configuration.
        hosting.sizingOptions = []
        panel.contentView = hosting

        let tracker = progress
        tracker.beat(0)
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let state = tracker.snapshot()
                if state.done { return }
                if state.delay > 8 {
                    let message = "FAIL: main loop stalled for over 8 seconds after \(state.count) scroll requests.\n"
                    FileHandle.standardError.write(Data(message.utf8))
                    _exit(2)
                }
            }
        }

        // Lay out an off-screen native window without activation or UI events.
        panel.orderBack(nil)
        applyCompactCase(compactCases[0])
        hosting.layoutSubtreeIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    private func step() {
        hosting.layoutSubtreeIfNeeded()
        progress.beat(iteration)
        if compactIndex < compactCases.count {
            settlingTicks += 1
            guard settlingTicks >= 3 else { return }
            checkCompactCase(compactCases[compactIndex])
            compactIndex += 1
            if compactIndex < compactCases.count {
                applyCompactCase(compactCases[compactIndex])
            } else {
                // Do not recreate RootView: a previously measured short height
                // must grow into a full scrolling viewport after this update.
                store.lists = TaskStore.longLists()
            }
            return
        }
        if restoringCompact {
            settlingTicks += 1
            guard settlingTicks >= 3 else { return }
            checkCompactCase(compactCases.last!, afterLong: true)
            finish()
            return
        }
        if let scroll = findScrollView(hosting), let document = scroll.documentView {
            let viewport = scroll.contentView.bounds
            let maximumOffset = max(0, document.frame.height - viewport.height)
            geometrySamples += 1
            widths.insert(Int(panel.frame.width))
            largestOffset = max(largestOffset, viewport.minY)
            if viewport.height >= panel.frame.height - 150 && maximumOffset > 500 {
                filledLongViewports += 1
            }
            // Five points of card padding remain beyond either scroll target.
            if iteration > 0, driver.target == "list-0", abs(viewport.minY) < 8 {
                topArrivals += 1
            }
            if iteration > 0, driver.target == "list-23", maximumOffset > 10,
               abs(viewport.minY - maximumOffset) < 8 {
                bottomArrivals += 1
            }
        }
        guard iteration < iterations else {
            restoringCompact = true
            settlingTicks = 0
            driver.target = ""
            // Again keep the same RootView alive. A tall window must not keep
            // an obsolete long-list viewport after returning to short content.
            store.lists = compactCases.last!.lists
            panel.setContentSize(NSSize(width: 280, height: 800))
            return
        }
        if iteration % 8 == 0 {
            let values: [CGFloat] = [240, 280, 460, 250]
            var frame = panel.frame
            frame.size.width = values[(iteration / 8) % values.count]
            frame.size.height = iteration % 16 == 0 ? 360 : 640
            panel.setFrame(frame, display: false)
        }
        driver.target = iteration % 2 == 0 ? "list-23" : "list-0"
        driver.pulse += 1
        iteration += 1
    }

    private func setCollapsedIDs(_ ids: [String]) {
        var overrides = originalArgumentDomain
        overrides["FloatTasks.collapsedListIDs"] = ids
        UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
    }

    private func applyCompactCase(_ fixture: CompactCase) {
        settlingTicks = 0
        setCollapsedIDs(fixture.collapsedIDs)
        store.connectionState = "Live"
        store.lists = fixture.lists
        driver.contentIdentity += 1
        panel.setContentSize(NSSize(width: fixture.width, height: 640))
    }

    private func checkCompactCase(_ fixture: CompactCase, afterLong: Bool = false) {
        compactChecks += 1
        let name = "\(afterLong ? "after long" : fixture.name) at \(Int(fixture.width))pt"
        guard let scroll = findScrollView(hosting), let document = scroll.documentView else {
            compactFailures.append("\(name): native scroll geometry unavailable")
            return
        }
        let viewportHeight = scroll.contentView.bounds.height
        let documentHeight = document.frame.height
        let scrollFrame = panel.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        var failures: [String] = []
        if viewportHeight < 20 || viewportHeight > fixture.maximumViewportHeight {
            failures.append("short viewport \(Int(viewportHeight)) exceeds content budget \(Int(fixture.maximumViewportHeight))")
        }
        if abs(documentHeight - viewportHeight) > 4 {
            failures.append("short document/viewport height differs by \(Int(documentHeight - viewportHeight))pt")
        }
        // The header and padding precede the scroll view. Check its screen
        // position directly: centering the compact stack in a tall hosting view
        // would pass the height checks while leaving a large gap at the top.
        let topInset = panel.frame.maxY - scrollFrame.maxY
        if topInset < 35 || topInset > 85 {
            failures.append("compact content starts \(Int(topInset))pt below the panel top")
        }
        let expectedHeight: CGFloat = afterLong ? 800 : 640
        if abs(panel.frame.width - fixture.width) > 1 || abs(panel.frame.height - expectedHeight) > 1 {
            failures.append("content changed the window's explicit frame")
        }
        if fixture.name == "before long", !afterLong { firstTransitionHeight = viewportHeight }
        if afterLong, let firstTransitionHeight, abs(viewportHeight - firstTransitionHeight) > 3 {
            failures.append("short viewport changed from \(Int(firstTransitionHeight)) to \(Int(viewportHeight))pt after long content")
        }
        if !failures.isEmpty { compactFailures.append("\(name): " + failures.joined(separator: "; ")) }
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = findScrollView(child) { return scroll }
        }
        return nil
    }

    private func finish() {
        timer?.invalidate()
        progress.done()
        UserDefaults.standard.setVolatileDomain(originalArgumentDomain, forName: UserDefaults.argumentDomain)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let expected = iterations / 2
        // Allow two delayed target resolutions on a busy development machine.
        let passed = geometrySamples >= iterations && widths.count == 4 &&
            topArrivals >= expected - 2 && bottomArrivals >= expected - 2 &&
            filledLongViewports >= iterations - 2 && compactFailures.isEmpty
        let summary = "\(passed ? "PASS" : "FAIL"): \(iteration) scroll requests; " +
            "top \(topArrivals)/\(expected), bottom \(bottomArrivals)/\(expected); " +
            "\(geometrySamples) native geometry samples; widths \(widths.sorted()); " +
            "maximum offset \(Int(largestOffset)); \(filledLongViewports) full long-list viewports; " +
            "\(compactChecks) compact checks; elapsed \(String(format: "%.2f", elapsed))s.\n"
        FileHandle.standardOutput.write(Data(summary.utf8))
        if !passed {
            for failure in compactFailures { FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8)) }
            FileHandle.standardError.write(Data("Expected responsive layout and repeated arrivals at both scroll boundaries. Run in a logged-in macOS desktop session.\n".utf8))
        }
        _exit(passed ? 0 : 1)
    }
}

@main
private struct ScrollLayoutTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ScrollTestDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
