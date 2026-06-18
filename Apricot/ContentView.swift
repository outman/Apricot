import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            directoryRow

            Divider()

            statusRow

            if let url = appState.serverURL {
                urlRow(url: url)
            }

            if let message = appState.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(appState.isRunning ? "停止" : "启动") {
                    Task {
                        if appState.isRunning { await appState.stop() } else { await appState.start() }
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(appState.selectedFolderURL == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 380)
    }

    private var directoryRow: some View {
        HStack(spacing: 12) {
            Text("共享目录").font(.headline)
            Text(appState.selectedFolderURL?.path ?? "未选择")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("选择…") { chooseFolder() }
                .disabled(appState.isRunning)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.isRunning ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(appState.statusText)
                .foregroundStyle(.secondary)
        }
    }

    private func urlRow(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(url.absoluteString)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button(copied ? "已复制" : "复制") { copy(url) }
                Button("在浏览器打开") { NSWorkspace.shared.open(url) }
            }
            if let qr = QRCodeImage.make(from: url.absoluteString) {
                Image(nsImage: qr)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 150, height: 150)
                    .accessibilityLabel("访问地址二维码")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "分享"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.chooseFolder(url)
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
