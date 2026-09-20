import AppKit
import Observation
import SwiftUI

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class StatusItemController: NSObject {
    private let store: NowPlayingStore
    private let preferences: Preferences
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var hosting: PassthroughHostingView<AnyView>?
    private var hostedHeight: CGFloat = 0
    private let settings: SettingsWindowController
    private let updater: UpdateController
    /// The slot's width follows the pill: full while playing, contracted around the idle
    /// mark once its shrink animation has landed. AppKit reflows the menu bar instantly,
    /// so this can never be animated — only sequenced.
    private var slotWork: DispatchWorkItem?
    private var slotWidth: CGFloat = 0
    private var slotWidthConstraint: NSLayoutConstraint?
    private var pillWidth: CGFloat {
        CompactIslandMetrics.pillWidth(count: preferences.visualizerBarCount)
    }
    /// Accessory apps do not reliably get transient popovers dismissed by clicks in
    /// other apps, so watch for clicks ourselves while the popover is up.
    private var clickAwayMonitors: [Any] = []

    init(
        store: NowPlayingStore,
        preferences: Preferences,
        settings: SettingsWindowController,
        updater: UpdateController
    ) {
        self.store = store
        self.preferences = preferences
        self.settings = settings
        self.updater = updater
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(handleClick(_:))

        let height = max(button.bounds.height, 22)
        hostedHeight = height
        let root = AnyView(
            CompactIslandView(buttonHeight: height)
                .environment(store)
                .environment(preferences)
        )
        let view = PassthroughHostingView(rootView: root)
        // The pill has a fixed size. Without this, NSHostingView re-runs
        // updateConstraints/layout for the whole button on every animation frame.
        view.sizingOptions = []
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        // The width constraint is what sizes a variable-length status item: setting
        // `NSStatusItem.length` looked like it worked (the property read back 37) but the
        // item kept its old footprint, because the button was still being measured from
        // these constraints. So the slot's width is driven from here instead.
        let width = view.widthAnchor.constraint(equalToConstant: pillWidth)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            view.topAnchor.constraint(equalTo: button.topAnchor),
            view.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            width,
        ])
        slotWidthConstraint = width
        slotWidth = pillWidth
        hosting = view

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = ExpandedIslandMetrics.size
        // The card is built on first open (see togglePopover); a hosting tree that may
        // never be shown is not worth keeping resident.

        // Nothing has reported yet, so this reaches its conclusion at once: an app that
        // launches idle starts as the mark, not as a pill that shrinks a second later.
        applyPresence(immediate: true)
        startObserving()
    }

    /// The status item is persistent now; a relaunch attempt just brings the
    /// existing instance forward, so there is nothing to reveal.
    func showReopenSafety() {
        DebugLog.line("reopen requested; status item is always visible")
    }

    private func startObserving() {
        tick()
    }

    private func tick() {
        withObservationTracking {
            applyVisibility()
            applyPresence(immediate: false)
            _ = store.audioPermissionDenied
            _ = store.isPlaying
            _ = store.session?.paletteKey
            _ = preferences.launchAtLogin
            _ = preferences.visualizerBarCount
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.tick() }
        }
    }

    /// Contracts the slot once the pill's shrink spring has landed, and expands it up
    /// front so the pill grows into space that is already there. The idle mark is drawn
    /// at the slot's final trailing inset the whole time, so the snap itself moves
    /// nothing on screen; only the neighbouring status items reflow, which AppKit does
    /// without animation and which no amount of sequencing here could smooth.
    private func applyPresence(immediate: Bool) {
        slotWork?.cancel()
        slotWork = nil
        guard !store.isPlaying else {
            setSlotWidth(pillWidth)
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !immediate, !reduceMotion else {
            setSlotWidth(CompactIslandMetrics.idleSlotWidth)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.setSlotWidth(CompactIslandMetrics.idleSlotWidth)
        }
        slotWork = work
        // Longer than the content's `smooth` shrink, so the slot only snaps once the
        // mark has come to rest.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func setSlotWidth(_ width: CGFloat) {
        guard width != slotWidth else { return }
        slotWidth = width
        slotWidthConstraint?.constant = width
        DebugLog.line("status item slot width=\(Int(width))")
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            DebugLog.line(
                "slot layout length=\(Int(self.statusItem.length)) button=\(button.frame) "
                    + "window=\(button.window?.frame ?? .zero)"
            )
        }
    }

    func applyVisibility() {
        // Persistent pill: always visible. When nothing plays it contracts to the idle mark.
        if !statusItem.isVisible {
            statusItem.isVisible = true
            DebugLog.line("statusItem.isVisible=true")
        }
        // The hosted view observes the store itself; replacing the root view here
        // on every Now Playing update forced a constraints + layout pass each time.
        if let hosting, let button = statusItem.button {
            let height = max(button.bounds.height, 22)
            guard height != hostedHeight else { return }
            hostedHeight = height
            hosting.rootView = AnyView(
                CompactIslandView(buttonHeight: height)
                    .environment(store)
                    .environment(preferences)
            )
        }
    }

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent, let button = statusItem.button else { return }
        if event.type == .rightMouseUp {
            contextMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopoverIfShown()
        } else {
            popover.contentViewController = makeExpandedController()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installClickAwayMonitors()
        }
    }

    /// The card has a fixed size. Without clearing `sizingOptions` the hosting view
    /// re-measures the popover frame on every bar frame while the popover is open.
    private func makeExpandedController() -> NSHostingController<some View> {
        let controller = NSHostingController(
            rootView: ExpandedIslandView()
                .environment(store)
                .environment(preferences)
        )
        controller.sizingOptions = []
        controller.view.frame = NSRect(origin: .zero, size: ExpandedIslandMetrics.size)
        return controller
    }

    private func installClickAwayMonitors() {
        removeClickAwayMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.closePopoverIfShown() }
        }) {
            clickAwayMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            let popoverWindow = self.popover.contentViewController?.view.window
            let inPopover = event.window != nil && event.window == popoverWindow
            let onButton = event.window != nil && event.window == self.statusItem.button?.window
            if !inPopover && !onButton {
                Task { @MainActor in self.closePopoverIfShown() }
            }
            return event
        }) {
            clickAwayMonitors.append(local)
        }
    }

    private func removeClickAwayMonitors() {
        for monitor in clickAwayMonitors {
            NSEvent.removeMonitor(monitor)
        }
        clickAwayMonitors.removeAll()
    }

    private func closePopoverIfShown() {
        removeClickAwayMonitors()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        if let release = updater.status.release, !updater.status.isInstalling {
            let item = NSMenuItem(
                title: "Update to IslandBar \(release.version)…",
                action: #selector(showUpdate),
                keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if store.audioPermissionDenied {
            let item = NSMenuItem(
                title: "Enable audio analysis…",
                action: #selector(openAudioPrivacy),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if store.browserAccessDenied {
            let item = NSMenuItem(
                title: "Allow reading browser tabs…",
                action: #selector(openAutomationPrivacy),
                keyEquivalent: ""
            )
            item.target = self
            item.toolTip = "IslandBar reads the playing tab's title from the browser when the browser reports no track. Enable it under Privacy & Security › Automation."
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let login = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLogin),
            keyEquivalent: ""
        )
        login.target = self
        login.state = preferences.launchAtLogin ? .on : .off
        menu.addItem(login)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let updates = NSMenuItem(
            title: updater.status.isInstalling ? "Installing Update…" : "Check for Updates…",
            action: #selector(showUpdate),
            keyEquivalent: ""
        )
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openAudioPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAutomationPrivacy() {
        store.retryBrowserAccess?()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        preferences.launchAtLogin.toggle()
    }

    @objc private func showSettings() {
        settings.show()
    }

    @objc private func showUpdate() {
        updater.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        removeClickAwayMonitors()
    }
}
