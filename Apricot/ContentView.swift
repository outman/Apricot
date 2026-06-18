import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                brand

                folderRow

                statusRow

                Divider()

                if appState.isRunning, let url = appState.serverURL {
                    urlRow(url: url)
                    qrView(url: url)
                } else {
                    skeleton
                }

                if let message = appState.errorMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 30)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            actionButton
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(width: 400, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Sections

    private var brand: some View {
        HStack(spacing: 12) {
            Image("logo")
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("Apricot")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Share folders on your LAN")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var folderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(appState.selectedFolderURL == nil
                 ? "No folder selected"
                 : appState.selectedFolderURL!.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(appState.selectedFolderURL == nil ? Color.secondary : .primary)
            Spacer(minLength: 8)
            Button("Choose…") { chooseFolder() }
                .disabled(appState.isRunning)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(appState.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func urlRow(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(url.absoluteString)
                .font(.system(.subheadline, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button {
                    copy(url)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13))
                        Text(copied ? "Copied" : "Copy")
                            .lineLimit(1)
                    }
                    .frame(width: 96, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "safari")
                            .font(.system(size: 13))
                        Text("Open in Browser")
                            .lineLimit(1)
                    }
                    .frame(width: 150, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()
            }
        }
    }

    /// Placeholder shown while idle, mirroring the running layout so the window is stable.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.quaternary)
                .frame(height: 14)
                .frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 90, height: 24)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 130, height: 24)
            }
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 104, height: 104)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func qrView(url: URL) -> some View {
        if let qr = QRCodeImage.make(from: url.absoluteString) {
            HStack {
                Spacer()
                Image(nsImage: qr)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 104, height: 104)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white)
                    )
                Spacer()
            }
            .accessibilityLabel("Address QR code")
        }
    }

    private var actionButton: some View {
        Button {
            Task {
                if appState.isRunning { await appState.stop() } else { await appState.start() }
            }
        } label: {
            Text(appState.isRunning ? "Stop Sharing" : "Start Sharing")
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
        panel.prompt = String(localized: "Share")
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
