import Foundation
import Observation

@Observable
final class AppState {
    var selectedFolderURL: URL?
    var isRunning: Bool = false
    var serverURL: URL?
    var statusText: String = String(localized: "Not running")
    var errorMessage: String?

    private let server = FileShareServer()
    private var scopedFolder: URL?

    init() {
        if let saved = BookmarkStore.load(), FileManager.default.fileExists(atPath: saved.path) {
            self.selectedFolderURL = saved
        }
    }

    func chooseFolder(_ url: URL) {
        if let previous = scopedFolder {
            previous.stopAccessingSecurityScopedResource()
            scopedFolder = nil
        }
        selectedFolderURL = url
        BookmarkStore.save(url: url)
        errorMessage = nil
    }

    func start() async {
        guard !isRunning else { return }
        guard let folder = selectedFolderURL else {
            errorMessage = String(localized: "Please choose a folder to share first.")
            return
        }
        errorMessage = nil
        statusText = String(localized: "Starting…")

        let acquired = folder.startAccessingSecurityScopedResource()
        do {
            try await server.start(rootURL: folder, preferredPort: FileShareServer.defaultPort)
            let ip = LocalNetwork.bestIPv4(from: LocalNetwork.ipv4Addresses()) ?? "127.0.0.1"
            if ip == "127.0.0.1" {
                errorMessage = String(localized: "No LAN IPv4 address found; using 127.0.0.1 (this machine only).")
            }
            var components = URLComponents()
            components.scheme = "http"
            components.host = ip
            components.port = server.boundPort
            serverURL = components.url
            scopedFolder = acquired ? folder : nil
            isRunning = true
            statusText = String(localized: "Running · port \(server.boundPort)")
        } catch {
            if acquired { folder.stopAccessingSecurityScopedResource() }
            scopedFolder = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusText = String(localized: "Not running")
            isRunning = false
        }
    }

    func stop() async {
        await server.stop()
        isRunning = false
        serverURL = nil
        statusText = String(localized: "Not running")
        if let folder = scopedFolder {
            folder.stopAccessingSecurityScopedResource()
            scopedFolder = nil
        }
    }
}
