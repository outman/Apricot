import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var copied = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            card
                .padding(.top, 32)      // clear the floating traffic-light buttons
                .padding(.bottom, 24)
                .padding(.horizontal, 24)
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 420, idealHeight: 460)
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 18) {
            brand

            folderRow

            if appState.isRunning, let url = appState.serverURL {
                Divider()
                statusRow
                urlRow(url: url)
                qrView(url: url)
            } else {
                statusRow
            }

            if let message = appState.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            actionButton
        }
        .padding(24)
        .frame(maxWidth: 440)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 6)
    }

    // MARK: Sections

    private var brand: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            Text("Apricot")
                .font(.title2)
                .fontWeight(.semibold)
            Text("局域网文件分享")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var folderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(appState.selectedFolderURL?.path ?? "未选择目录")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("选择…") { chooseFolder() }
                .disabled(appState.isRunning)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.isRunning ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
            Text(appState.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func urlRow(url: URL) -> some View {
        VStack(spacing: 10) {
            Text(url.absoluteString)
                .font(.system(.subheadline, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                Button {
                    copy(url)
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("在浏览器打开", systemImage: "safari")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func qrView(url: URL) -> some View {
        if let qr = QRCodeImage.make(from: url.absoluteString) {
            Image(nsImage: qr)
                .resizable()
                .interpolation(.none)
                .frame(width: 128, height: 128)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white)
                )
                .accessibilityLabel("访问地址二维码")
        }
    }

    private var actionButton: some View {
        Button {
            Task {
                if appState.isRunning { await appState.stop() } else { await appState.start() }
            }
        } label: {
            Text(appState.isRunning ? "停止分享" : "开始分享")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(appState.selectedFolderURL == nil)
    }

    // MARK: Actions

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
