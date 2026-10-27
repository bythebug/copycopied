import AppKit
import BackedCore
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = AppModel()
    private var mainWindow: NSWindow?
    private var anchor: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(rootView: PopoverView(model: model) { [weak self] in self?.openMain() })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.setAccessibilityLabel("backed.")

        model.onCardInserted = { [weak self] in self?.showPopover() }
        model.onChange = { [weak self] in self?.updateIcon() }
        model.isPopoverShown = { [weak self] in self?.popover.isShown ?? false }
        updateIcon()

        // ponytail: NSWorkspace mount notifications are enough to notice cards. DiskArbitration arrives
        // with the read-only remount (PLAN.md D7/Q1), which needs a DA mount-approval callback anyway.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
    }

    private func refresh() { Task { await model.refresh() } }

    /// "b." with a dot in the worst verdict's colour; no dot when no card is in (spec 6.1).
    private func updateIcon() {
        let title = NSMutableAttributedString(string: "b.", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .heavy)])
        if let worst = model.worst {
            title.append(NSAttributedString(string: " ●", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: worst.nsColor, .baselineOffset: 1.5,
            ]))
        }
        statusItem.button?.attributedTitle = title
        statusItem.button?.setAccessibilityValue(model.worst.map { "\($0.rawValue)" } ?? "no card")
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        if let f = button.window?.frame, NSScreen.screens.contains(where: { $0.frame.contains(f) }) {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else {
            // The icon is hidden (notch or a crowded menu bar), so hang the popover under the top-right corner instead.
            let anchor = anchorPanel()
            popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func anchorPanel() -> NSPanel {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(x: screen.visibleFrame.maxX - 200, y: screen.visibleFrame.maxY - 1, width: 1, height: 1)
        let panel = anchor ?? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(frame, display: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hidesOnDeactivate = false  // backed. is rarely the active app; a hiding anchor would close the popover
        panel.orderFrontRegardless()
        anchor = panel
        return panel
    }

    private func openMain() {
        popover.performClose(nil)
        if mainWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: MainView()))
            w.title = "backed."
            w.isReleasedWhenClosed = false
            mainWindow = w
        }
        mainWindow?.center()
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
