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
    let canEdit = false
    var visibleLists: [TaskList] { lists }
    var filteredLists: [TaskList] { lists }

    init() {
        let sizes = [1, 4, 55, 2, 21, 6, 75, 3]
        lists = (0..<24).map { i in
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
    func openGoogleTasks() { fatalError("Layout tests must not open a browser") }
    func toggleCompletion(task: GoogleTask, list: TaskList) { fatalError("Read-only fixture") }
    func addTask(title: String, list: TaskList) { fatalError("Read-only fixture") }
}

@MainActor
private final class ScrollDriver: ObservableObject {
    @Published var target = ""
    @Published var pulse = 0
}

private struct ScrollTestView: View {
    @ObservedObject var driver: ScrollDriver
    @ObservedObject var store: TaskStore

    var body: some View {
        ScrollViewReader { proxy in
            RootView(store: store, onPin: {}, onHide: {}, onSettings: {}, isPinned: false)
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
    private let startedAt = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // The test executable has its own preferences domain, not the app's.
        UserDefaults.standard.set([], forKey: "FloatTasks.collapsedListIDs")
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
        hosting.layoutSubtreeIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    private func step() {
        hosting.layoutSubtreeIfNeeded()
        if let scroll = findScrollView(hosting), let document = scroll.documentView {
            let viewport = scroll.contentView.bounds
            let maximumOffset = max(0, document.frame.height - viewport.height)
            geometrySamples += 1
            widths.insert(Int(panel.frame.width))
            largestOffset = max(largestOffset, viewport.minY)
            // Five points of card padding remain beyond either scroll target.
            if iteration > 0, driver.target == "list-0", abs(viewport.minY) < 8 {
                topArrivals += 1
            }
            if iteration > 0, driver.target == "list-23", maximumOffset > 10,
               abs(viewport.minY - maximumOffset) < 8 {
                bottomArrivals += 1
            }
        }
        progress.beat(iteration)
        guard iteration < iterations else { finish(); return }
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
        UserDefaults.standard.removeObject(forKey: "FloatTasks.collapsedListIDs")
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let expected = iterations / 2
        // Allow two delayed target resolutions on a busy development machine.
        let passed = geometrySamples >= iterations && widths.count == 4 &&
            topArrivals >= expected - 2 && bottomArrivals >= expected - 2
        let summary = "\(passed ? "PASS" : "FAIL"): \(iteration) scroll requests; " +
            "top \(topArrivals)/\(expected), bottom \(bottomArrivals)/\(expected); " +
            "\(geometrySamples) native geometry samples; widths \(widths.sorted()); " +
            "maximum offset \(Int(largestOffset)); elapsed \(String(format: "%.2f", elapsed))s.\n"
        FileHandle.standardOutput.write(Data(summary.utf8))
        if !passed {
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
