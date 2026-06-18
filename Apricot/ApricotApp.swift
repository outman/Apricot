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
}

@main
struct ApricotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appDelegate.appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 460)
    }
}
