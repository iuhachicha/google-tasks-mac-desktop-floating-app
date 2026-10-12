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
    private var accessibilityObserver: NSObjectProtocol?
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
        applyPanelOpacity()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPanelOpacity() }
        }
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
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        store.oauth.cancelSignIn()
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Float Tasks · Settings"
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        // Re-sample the panel's current width and saved opacity on each opening.
        let hosting = NSHostingView(rootView: SettingsView(store: store, oauth: store.oauth, delegate: self))
        hosting.sizingOptions = []
        settingsWindow?.contentView = hosting
        hide()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func resize(width: CGFloat) {
        var frame = panel.frame
        frame.origin.x += frame.width - width
        frame.size.width = width
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    func applyPanelOpacity() {
        let preferences = NSWorkspace.shared
        let opacity = UserDefaults.standard.double(forKey: "panelOpacity")
        let savedOpacity = opacity >= 0.45 ? min(opacity, 1) : 1
        panel.alphaValue = preferences.accessibilityDisplayShouldReduceTransparency
            || preferences.accessibilityDisplayShouldIncreaseContrast ? 1 : savedOpacity
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var opacity = 1.0
    @State private var panelWidth = 280

    private var requiresOpaquePanel: Bool { reduceTransparency || contrast == .increased }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Float Tasks").font(.title2.weight(.semibold))
                    Text("A little space for what’s next.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    connectionSection
                    appearanceSection
                    Label("Click the menu-bar icon to show your tasks. Pin the panel to keep it open.", systemImage: "menubar.rectangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Quit Float Tasks", action: delegate.quit)
                Spacer()
                Button("Done", action: delegate.closeSettings)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 440, height: 540)
        .onAppear {
            let savedOpacity = UserDefaults.standard.double(forKey: "panelOpacity")
            opacity = savedOpacity >= 0.45 ? min(savedOpacity, 1) : 1
            panelWidth = Int(delegate.panel.frame.width.rounded())
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Google Tasks").font(.headline)
                Spacer()
                if oauth.isSignedIn {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(oauth.isSignedIn
                 ? "Your tasks sync automatically. Changes save directly to Google."
                 : "Connect your account to see and manage your tasks here.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !oauth.isConfigured {
                Text("Import a Google Desktop OAuth client JSON with the Tasks API enabled to get started.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Import Google Client JSON…", action: delegate.importClient)
            } else if oauth.isSignedIn {
                if !oauth.hasWriteAccess {
                    Text("Enable editing to add, edit, complete, and delete tasks. Your list selection stays the same.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(oauth.isAuthorizing ? "Waiting for Google…" : "Enable Editing") { store.enableEditing() }
                            .buttonStyle(.borderedProminent)
                            .disabled(oauth.isAuthorizing || store.isMutating)
                        if oauth.isAuthorizing { Button("Cancel") { oauth.cancelSignIn() } }
                    }
                }
                Button("Disconnect") { store.disconnect() }
            } else {
                HStack {
                    Button(oauth.isAuthorizing ? "Waiting for Google…" : "Sign In with Google") { store.connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(oauth.isAuthorizing)
                    if oauth.isAuthorizing { Button("Cancel") { oauth.cancelSignIn() } }
                }
                Button("Use Another Google Client…", action: delegate.importClient)
            }
            if let error = store.error {
                Label {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.caption).foregroundStyle(.red)
            }
            Label("Sign-in is saved securely in your Mac’s Keychain.", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Panel").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Width").font(.callout)
                    Spacer()
                    Text("\(panelWidth) pt").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Picker("Panel width", selection: $panelWidth) {
                    Text("Narrow").tag(240)
                    Text("Standard").tag(280)
                    Text("Wide").tag(340)
                    if ![240, 280, 340].contains(panelWidth) { Text("Custom").tag(panelWidth) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: panelWidth) { delegate.resize(width: CGFloat($0)) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Opacity").font(.callout)
                    Spacer()
                    Text(requiresOpaquePanel ? "100%" : "\(Int((opacity * 100).rounded()))%")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $opacity, in: 0.45...1)
                    .accessibilityLabel("Panel opacity")
                    .accessibilityValue(requiresOpaquePanel ? "100 percent" : "\(Int((opacity * 100).rounded())) percent")
                    .disabled(requiresOpaquePanel)
                    .onChange(of: opacity) { value in
                        UserDefaults.standard.set(value, forKey: "panelOpacity")
                        delegate.applyPanelOpacity()
                    }
                if requiresOpaquePanel {
                    Text("Your Mac’s accessibility settings keep the panel opaque.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
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
