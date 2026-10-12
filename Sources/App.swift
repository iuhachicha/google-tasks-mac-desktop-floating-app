import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class WindowState: ObservableObject {
    @Published var pinned = UserDefaults.standard.object(forKey: "menuPanelPinned") as? Bool ?? false
}

struct AppRoot: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var state: WindowState
    let delegate: AppDelegate
    var body: some View {
        RootView(store: store, onPin: delegate.togglePin, onHide: delegate.hide,
                 onSettings: delegate.showSettings, isPinned: state.pinned)
            .tint(Color(red: 0.10, green: 0.61, blue: 0.43))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = TaskStore()
    let state = WindowState()
    var panel: FloatingPanel!
    var settingsWindow: NSWindow?
    var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var contextMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.onConnection = { [weak self] in self?.showSettings() }
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = "Float Tasks"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 240, height: 320)
        panel.maxSize = NSSize(width: 460, height: 1400)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let hosting = NSHostingView(rootView: AppRoot(store: store, state: state, delegate: self))
        // AppKit owns this panel's size; scrolling content must not feed its
        // changing measurements back into the hosting view's size constraints.
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        _ = panel.setFrameUsingName("FloatTasksPanel")
        panel.setFrameAutosaveName("FloatTasksPanel")
        let opacity = UserDefaults.standard.double(forKey: "panelOpacity")
        panel.alphaValue = opacity >= 0.45 ? min(opacity, 1) : 1
        applyPin()
        buildMenuBarItem()
        installDismissHandlers()
        // A menu-bar app starts tucked away. The status icon is its entry point.
    }

    func buildMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Float Tasks")
            button.image?.isTemplate = true
            button.toolTip = "Float Tasks — click to show or hide"
            button.setAccessibilityLabel("Float Tasks")
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        contextMenu = NSMenu()
        for (title, selector, key) in [
            ("Show / Hide Tasks", #selector(togglePanel), ""),
            ("Settings…", #selector(showSettings), ","),
            ("Refresh", #selector(refresh), "r"),
            ("Quit Float Tasks", #selector(quit), "q")
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            contextMenu.addItem(item)
        }
        let main = NSMenu()
        let application = NSMenuItem()
        let appMenu = NSMenu()
        for (title, selector, key) in [
            ("Settings…", #selector(showSettings), ","),
            ("Close Window", #selector(closeCurrentWindow), "w"),
            ("Quit Float Tasks", #selector(quit), "q")
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            appMenu.addItem(item)
        }
        application.submenu = appMenu
        main.addItem(application)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = contextMenu
            sender.performClick(nil)
            statusItem.menu = nil
        } else { togglePanel() }
    }

    @objc func togglePanel() { panel.isVisible ? hide() : show() }
    @objc func show() {
        if !state.pinned, let button = statusItem.button, let buttonWindow = button.window {
            let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = buttonWindow.screen ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                var frame = panel.frame
                frame.size.height = min(frame.height, visible.height - 16)
                frame.origin.x = min(max(anchor.midX - frame.width / 2, visible.minX + 8), visible.maxX - frame.width - 8)
                frame.origin.y = max(visible.minY + 8, min(anchor.minY - frame.height - 4, visible.maxY - frame.height))
                panel.setFrame(frame, display: false)
            }
        }
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        NSApp.activate(ignoringOtherApps: true)
        store.refreshIfNeeded()
    }
    @objc func hide() {
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }
    @objc func closeCurrentWindow() {
        if settingsWindow?.isKeyWindow == true { closeSettings() } else { hide() }
    }
    @objc func closeSettings() { settingsWindow?.orderOut(nil) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func refresh() { store.refresh() }
    func togglePin() {
        state.pinned.toggle()
        UserDefaults.standard.set(state.pinned, forKey: "menuPanelPinned")
        applyPin()
    }
    func applyPin() { panel.level = .floating }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel { hide() } else { sender.orderOut(nil) }
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(); return true
    }
    private func installDismissHandlers() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.state.pinned else { return }
                self.hide()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                if self.settingsWindow?.isKeyWindow == true { self.closeSettings() }
                else if self.panel.isVisible { self.hide() }
                else { return event }
                return nil
            }
            if event.type != .keyDown, !self.state.pinned, event.window !== self.panel,
               event.window !== self.settingsWindow, event.window !== self.statusItem.button?.window {
                self.hide()
            }
            return event
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        store.oauth.cancelSignIn()
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 510),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Float Tasks · Settings"
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(store: store, oauth: store.oauth, delegate: self))
            window.center()
            settingsWindow = window
        }
        hide()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func resize(width: CGFloat) {
        var frame = panel.frame
        frame.origin.x += frame.width - width
        frame.size.width = width
        panel.setFrame(frame, display: true, animate: true)
    }
    func importClient() {
        let picker = NSOpenPanel()
        picker.title = "Choose your Google Desktop OAuth client JSON"
        picker.allowedContentTypes = [.json]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard let settingsWindow else { return }
        picker.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, let url = picker.url else { return }
            Task { @MainActor in
                do { try self?.store.importClient(from: url); self?.store.error = nil }
                catch { self?.store.error = error.localizedDescription }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var oauth: GoogleOAuth
    let delegate: AppDelegate
    @State private var opacity = 1.0
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Float Tasks").font(.title2.weight(.semibold))
                    Text("Your tasks, a click from the menu bar.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: delegate.closeSettings)
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Google Tasks").font(.headline)
                Text(oauth.isSignedIn ? "Connected directly to Google. Your lists refresh automatically while the app is running." : "Sign in once to see your Google Tasks here. Chrome and browser extensions are not needed for syncing.")
                    .font(.callout).foregroundStyle(.secondary)
                if !oauth.isConfigured {
                    Text("One-time setup: import a Google OAuth client JSON created for a Desktop app, with Google Tasks API enabled.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Import Google client JSON…", action: delegate.importClient)
                } else if oauth.isSignedIn {
                    HStack {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Disconnect") { store.disconnect() }
                    }
                } else {
                    HStack {
                        Button(oauth.isAuthorizing ? "Waiting for Google…" : "Sign in with Google") { store.connect() }
                            .buttonStyle(.borderedProminent)
                            .disabled(oauth.isAuthorizing)
                        if oauth.isAuthorizing {
                            Button("Cancel") { oauth.cancelSignIn() }
                        }
                    }
                    Button("Use another Google client…", action: delegate.importClient).font(.caption)
                }
                if let error = store.error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text("Read-only access. Sign-in tokens are stored in your Mac’s Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("Width").font(.headline)
                Spacer()
                ForEach([240, 280, 340], id: \.self) { width in
                    Button(String(width)) { delegate.resize(width: CGFloat(width)) }
                }
            }
            HStack {
                Text("Opacity").font(.headline)
                Slider(value: $opacity, in: 0.45...1).onChange(of: opacity) { value in
                    delegate.panel.alphaValue = value
                    UserDefaults.standard.set(value, forKey: "panelOpacity")
                }
            }
            Text("Click the menu-bar icon to show or hide. Escape or a click outside dismisses the panel. Pin keeps it open.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Open Google Tasks", action: store.openGoogleTasks)
                Spacer()
                Button("Quit", action: delegate.quit)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { opacity = delegate.panel.alphaValue }
    }
}

@main
struct FloatTasksMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
