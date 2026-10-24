import AppKit
import Combine
import SwiftUI

/// The menu bar icon and the dropdown panel attached under it.
///
/// SwiftUI's `MenuBarExtra(.window)` keeps the window's bottom edge fixed when its content
/// changes height, so after a section collapses the panel drifts down away from the menu bar.
/// This controller resizes the panel itself and always keeps its top edge pinned under the icon.
final class StatusPanelController: NSObject, NSWindowDelegate {
    static let gapBelowMenuBar: CGFloat = 5
    static let screenMargin: CGFloat = 8
    /// A click on the icon can close the panel (focus loss / outside-click monitor) just before the
    /// icon's own action runs. Closes this recent count as part of that same click.
    static let sameClickInterval: TimeInterval = 0.3
    static let openDuration: TimeInterval = 0.18
    static let closeDuration: TimeInterval = 0.12
    /// How far the panel slides down into place as it opens (and back up as it closes).
    static let slideDistance: CGFloat = 6

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = DropdownPanel()
    let navigation = MenuNavigation()
    private var contentSize = CGSize(width: 300, height: 400)
    private var eventMonitors: [Any] = []
    private var iconSubscription: AnyCancellable?
    private var layoutSubscriptions: [AnyCancellable] = []
    private var autoClosedAt: TimeInterval = -.infinity
    /// Open from the user's point of view. The panel stays on screen a moment longer while it fades out.
    private var isOpen = false
    /// Bumped on every show and close so a finished close animation never hides a reopened panel.
    private var transition = 0
    private var hostingController: NSHostingController<AnyView>!

    init(manager: SessionManager, settings: Settings, updater: UpdateChecker) {
        super.init()

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        // This controller is the only thing that sizes the panel. The hosting view gets no sizing
        // constraints, because Auto Layout would otherwise resize the window behind our back
        // (unanimated, and away from the icon). While open, the menu reports its height whenever it
        // changes; on opening it's measured directly, since SwiftUI doesn't update hidden windows.
        // Top-aligned so content never jumps while the panel animates to a new height.
        hostingController = NSHostingController(rootView: AnyView(
            MenuView(manager: manager, settings: settings, updater: updater, navigation: navigation)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: MenuSizeKey.self, value: proxy.size)
                })
                .onPreferenceChange(MenuSizeKey.self) { [weak self] size in
                    DispatchQueue.main.async { self?.contentSizeChanged(size) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
        ))
        hostingController.sizingOptions = []
        let hosting = hostingController.view
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        panel.contentView = background
        panel.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityTitle("Wakeful")
        }
        iconSubscription = manager.$session.sink { [weak self] session in
            self?.statusItem.button?.image = session == nil ? StatusIcon.inactive : StatusIcon.active
        }
        // These change the menu's height. Measure once the change has landed.
        for publisher in [navigation.objectWillChange.eraseToAnyPublisher(),
                          manager.$session.map { _ in () }.eraseToAnyPublisher()] {
            layoutSubscriptions.append(publisher.sink { [weak self] in
                DispatchQueue.main.async { self?.remeasure() }
            })
        }
    }

    var isPanelVisible: Bool { isOpen }
    var panelFrame: NSRect { panel.frame }
    var panelFirstResponder: NSResponder? { panel.firstResponder }

    // MARK: - Showing and hiding

    @objc func togglePanel() {
        if isOpen {
            closePanel()
        } else if ProcessInfo.processInfo.systemUptime - autoClosedAt < Self.sameClickInterval {
            // This click already closed the panel on its way to the icon; don't reopen it.
            autoClosedAt = -.infinity
        } else {
            showPanel()
        }
    }

    func showPanel() {
        remeasure()
        isOpen = true
        transition += 1
        let frame = targetFrame() ?? panel.frame
        // A panel still fading out from a close is picked up where it is instead of restarting.
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(Self.reduceMotion ? frame : frame.offsetBy(dx: 0, dy: Self.slideDistance), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        // Open with nothing focused, like a menu: with keyboard navigation turned on, macOS would
        // otherwise draw a focus ring around the first control. Tab still moves into the menu.
        panel.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen else { return }
            self.panel.makeFirstResponder(nil)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.openDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            self?.panel.invalidateShadow()
        })
        // Keep the icon highlighted like an open menu (the click itself un-highlights it on mouse up).
        DispatchQueue.main.async { self.statusItem.button?.highlight(true) }
        startMonitoringEvents()
    }

    func closePanel() {
        guard isOpen else { return }
        isOpen = false
        transition += 1
        let closing = transition
        statusItem.button?.highlight(false)
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.closeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            if !Self.reduceMotion {
                panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: Self.slideDistance), display: true)
            }
        }, completionHandler: { [weak self] in
            guard let self, self.transition == closing else { return }
            self.panel.orderOut(nil)
        })
    }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Closing because of a click elsewhere or focus loss, rather than the icon itself.
    func closePanelAutomatically() {
        guard isOpen else { return }
        autoClosedAt = ProcessInfo.processInfo.systemUptime
        closePanel()
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanelAutomatically()
    }

    /// Closes on clicks in other apps and on Esc, like a menu.
    private func startMonitoringEvents() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.closePanelAutomatically()
        }) {
            eventMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            self?.closePanel()
            return nil
        }) {
            eventMonitors.append(monitor)
        }
    }

    // MARK: - Layout

    /// Measures the menu directly. Unlike the size the menu reports while rendering, this also
    /// works while the panel is hidden.
    private func remeasure() {
        // Applies pending SwiftUI changes first; otherwise the size lags one change behind.
        hostingController.view.layoutSubtreeIfNeeded()
        contentSizeChanged(hostingController.sizeThatFits(in: CGSize(width: MenuView.width, height: 0)))
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        if isOpen {
            resizePanel()
        }
    }

    private func resizePanel() {
        guard let frame = targetFrame() else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MenuView.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    /// Where the panel sits when fully open, or nil if the icon isn't on screen yet.
    private func targetFrame() -> NSRect? {
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main
        else { return nil }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return Self.panelFrame(contentSize: contentSize, below: anchor, in: screen.visibleFrame)
    }

    /// Frame for the panel: top edge just under the icon, left-aligned with it, kept on screen.
    static func panelFrame(contentSize: CGSize, below anchor: NSRect, in visibleFrame: NSRect) -> NSRect {
        let top = min(anchor.minY, visibleFrame.maxY) - gapBelowMenuBar
        let height = max(min(contentSize.height, top - visibleFrame.minY - screenMargin), 0)
        let x = max(min(anchor.minX, visibleFrame.maxX - contentSize.width - screenMargin),
                    visibleFrame.minX + screenMargin)
        return NSRect(x: x, y: top - height, width: contentSize.width, height: height)
    }
}

private struct MenuSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// Borderless panel that can take keyboard focus without activating the app, like a menu.
private final class DropdownPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
}
