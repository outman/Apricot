import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = StatusItemController(appState: appState)
        item.install()
        statusItem = item
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort graceful shutdown. The OS reclaims the listening port on exit regardless,
        // so we don't block terminate (blocking main + a MainActor async stop would deadlock).
        Task { await appState.stop() }
    }

    /// Captured from the SwiftUI layer so AppKit menu items can (re)open the window even after
    /// it has been closed (SwiftUI tears the window scene down on close).
    func captureOpenWindow(_ action: OpenWindowAction) {
        statusItem?.openWindow = action
    }
}

/// Invisible view whose only job is to read the SwiftUI `openWindow` action and hand it to the
/// AppKit status-item controller, since `openWindow` isn't available at the App/Scene level.
private struct OpenWindowBridge: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear { appDelegate.captureOpenWindow(openWindow) }
    }
}

@main
struct ApricotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appDelegate.appState)
                .background(OpenWindowBridge(appDelegate: appDelegate))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 480)
    }
}
