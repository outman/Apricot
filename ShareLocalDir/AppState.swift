import Foundation
import Observation

@Observable
final class AppState {
    var selectedFolderURL: URL?
    var isRunning: Bool = false
    var serverURL: URL?
    var statusText: String = "未运行"
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
            errorMessage = "请先选择一个要分享的目录。"
            return
        }
        errorMessage = nil
        statusText = "启动中…"

        let acquired = folder.startAccessingSecurityScopedResource()
        do {
            try await server.start(rootURL: folder, preferredPort: FileShareServer.defaultPort)
            let ip = LocalNetwork.bestIPv4(from: LocalNetwork.ipv4Addresses()) ?? "127.0.0.1"
            if ip == "127.0.0.1" {
                errorMessage = "未检测到局域网 IPv4 地址，将使用 127.0.0.1（仅本机可访问）。"
            }
            var components = URLComponents()
            components.scheme = "http"
            components.host = ip
            components.port = server.boundPort
            serverURL = components.url
            scopedFolder = acquired ? folder : nil
            isRunning = true
            statusText = "运行中 · 端口 \(server.boundPort)"
        } catch {
            if acquired { folder.stopAccessingSecurityScopedResource() }
            scopedFolder = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusText = "未运行"
            isRunning = false
        }
    }

    func stop() async {
        await server.stop()
        isRunning = false
        serverURL = nil
        statusText = "未运行"
        if let folder = scopedFolder {
            folder.stopAccessingSecurityScopedResource()
            scopedFolder = nil
        }
    }
}
