import AppKit

final class StatusItemController: NSObject {
    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var iconTimer: Timer?

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

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        iconTimer = timer
    }

    deinit {
        iconTimer?.invalidate()
    }

    @MainActor
    private func refreshIcon() {
        statusItem?.button?.title = appState.isRunning ? "●" : "○"
        statusItem?.button?.toolTip = "ShareLocalDir · \(appState.statusText)"
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = menu.addItem(withTitle: "ShareLocalDir", action: nil, keyEquivalent: "")
        header.isEnabled = false

        if let url = appState.serverURL {
            menu.addItem(.separator())
            menu.addItem(withTitle: "复制地址", action: #selector(copyAddress), keyEquivalent: "c").target = self
            menu.addItem(withTitle: "在浏览器打开", action: #selector(openInBrowser), keyEquivalent: "").target = self
            let addr = menu.addItem(withTitle: url.absoluteString, action: nil, keyEquivalent: "")
            addr.isEnabled = false
        }

        menu.addItem(.separator())
        let toggleTitle = appState.isRunning ? "停止" : "启动"
        menu.addItem(withTitle: toggleTitle, action: #selector(toggleRunning), keyEquivalent: "").target = self
        menu.addItem(withTitle: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ShareLocalDir", action: #selector(quit), keyEquivalent: "q").target = self
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
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
