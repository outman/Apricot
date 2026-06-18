import AppKit
import SwiftUI

final class StatusItemController: NSObject {
    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var iconTimer: Timer?

    /// Captured from the SwiftUI environment so the AppKit menu can reopen the window after it
    /// has been closed (SwiftUI tears the window scene down on close).
    var openWindow: OpenWindowAction?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()

        // Target-action timer (no @Sendable closure) so we don't capture a non-Sendable
        // `self` across a concurrency boundary. The controller lives for the app lifetime.
        let timer = Timer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        iconTimer = timer
    }

    @objc private func tick() {
        refreshIcon()
    }

    deinit {
        iconTimer?.invalidate()
    }

    @MainActor
    private func refreshIcon() {
        let button = statusItem?.button
        let symbolName = appState.isRunning ? "cat.circle.fill" : "cat.circle"
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Apricot")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        icon?.isTemplate = true
        button?.image = icon
        button?.imagePosition = .imageOnly
        button?.toolTip = "Apricot · \(appState.statusText)"
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = menu.addItem(withTitle: "Apricot", action: nil, keyEquivalent: "")
        header.isEnabled = false

        if let url = appState.serverURL {
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Copy Address"), action: #selector(copyAddress), keyEquivalent: "c").target = self
            menu.addItem(withTitle: String(localized: "Open in Browser"), action: #selector(openInBrowser), keyEquivalent: "").target = self
            let addr = menu.addItem(withTitle: url.absoluteString, action: nil, keyEquivalent: "")
            addr.isEnabled = false
        }

        menu.addItem(.separator())
        let toggleTitle = appState.isRunning
            ? String(localized: "Stop")
            : String(localized: "Start")
        menu.addItem(withTitle: toggleTitle, action: #selector(toggleRunning), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Show Main Window"), action: #selector(showMainWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Apricot"), action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func copyAddress() {
        guard let url = appState.serverURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func openInBrowser() {
        guard let url = appState.serverURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleRunning() {
        Task {
            if appState.isRunning { await appState.stop() } else { await appState.start() }
        }
    }

    @objc private func showMainWindow() {
        NSApp.activate()
        // Skip the status item's own window (NSStatusBarWindow, canBecomeKeyWindow == NO) and
        // panels; only a real main window qualifies.
        if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // The window was closed, so SwiftUI tore the scene down — recreate it.
            openWindow?(id: "main")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
