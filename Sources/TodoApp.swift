import SwiftUI
import AppKit
import Combine
import Carbon.HIToolbox

/// App entry point. A menu-bar-only app (`LSUIElement` in Info.plist): the sole
/// UI is a status-bar item whose popover is the task panel.
///
/// We drive the status item ourselves via an `NSStatusItem` (rather than
/// SwiftUI's `MenuBarExtra`) so a left click can open the panel while a right
/// click opens the options menu.
@main
struct TodoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No SwiftUI-managed windows; the status item's popover is the whole UI.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = TaskStore()
    private let timer = TaskTimer()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var timerObservers: Set<AnyCancellable> = []
    /// What the status button currently shows, so ticks that don't change the
    /// visible `mm:ss` don't touch AppKit.
    private var statusTitle = ""

    /// Global shortcut: ⌃⌥⌘T toggles the panel from anywhere. Triple-modifier + T
    /// is chosen to steer clear of macOS and popular-app shortcuts.
    private lazy var openHotKey = GlobalHotKey(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    ) { [weak self] in
        self?.toggleFromHotKey()
    }

    private let shortcutsEnabledKey = "shortcutsEnabled"
    private var shortcutsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: shortcutsEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: shortcutsEnabledKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(store)
                .environmentObject(timer)
        )

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.menuIcon
            button.toolTip = "Zundra — click to open, right-click for options"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        // Mirror the running countdown in the menu bar: the clock for each tick,
        // the timer itself for starts and stops. `objectWillChange` fires
        // *before* the new value lands, hence the hop to the next run-loop pass.
        for publisher in [timer.objectWillChange, timer.clock.objectWillChange] {
            publisher.sink { [weak self] in
                DispatchQueue.main.async { self?.refreshStatusTitle() }
            }
            .store(in: &timerObservers)
        }

        // Restore the saved shortcut preference.
        if shortcutsEnabled { openHotKey.register() }

    }

    // MARK: - Clicks

    /// Left click toggles the panel; right click (or Control-click) opens the
    /// options menu.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { togglePopover(sender); return }
        let isSecondaryClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isSecondaryClick {
            showOptionsMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    // MARK: - Options menu (right-click)

    private func showOptionsMenu(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Keyboard shortcut", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let toggle = NSMenuItem(
            title: "Open Zundra   ⌃⌥⌘T",
            action: #selector(toggleShortcuts(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = shortcutsEnabled ? .on : .off
        toggle.toolTip = shortcutsEnabled
            ? "On — press ⌃⌥⌘T anywhere to open Tasks. Click to disable."
            : "Off — click to enable the ⌃⌥⌘T global shortcut."
        menu.addItem(toggle)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Zundra", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        // Pop the menu just below the icon.
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height + 4),
            in: sender
        )
    }

    @objc private func toggleShortcuts(_ item: NSMenuItem) {
        shortcutsEnabled.toggle()
        if shortcutsEnabled {
            openHotKey.register()
        } else {
            openHotKey.unregister()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Panel

    private func toggleFromHotKey() {
        guard let button = statusItem?.button else { return }
        togglePopover(button)
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            refreshStatusTitle()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            refreshStatusTitle()
            // Make the popover key so the capture field can take keyboard focus.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Menu-bar countdown

    /// Shows the remaining time next to the icon while a timer runs and the
    /// panel is closed — with the panel open the countdown already sits next to
    /// its task, so the menu bar stays uncluttered.
    private func refreshStatusTitle() {
        guard let button = statusItem?.button else { return }
        let title = (timer.isRunning && !popover.isShown) ? timer.display : ""
        guard title != statusTitle else { return }
        statusTitle = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        // Monospaced digits so the icon doesn't shuffle as the seconds tick.
        button.attributedTitle = NSAttributedString(
            string: title.isEmpty ? "" : " " + title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]
        )
    }

    func popoverDidShow(_ notification: Notification) { refreshStatusTitle() }
    func popoverDidClose(_ notification: Notification) { refreshStatusTitle() }

    /// The menu-bar icon: the brain glyph as an 18pt template image. Loaded from
    /// the @2x PNG so it stays crisp on Retina; `isTemplate` lets macOS tint it.
    private static let menuIcon: NSImage = {
        let image = Bundle.main.url(forResource: "MenuIconTemplate@2x", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(named: "MenuIconTemplate")
            ?? NSImage(systemSymbolName: "brain", accessibilityDescription: "Zundra")
            ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
