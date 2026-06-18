import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

enum FileShareError: Error, LocalizedError {
    case noPortAvailable(first: Int, attempted: Int)
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .noPortAvailable(let first, let n):
            return String(localized: "Ports \(first)-\(first + n - 1) are all in use; could not start the server.")
        case .alreadyRunning:
            return String(localized: "The server is already running.")
        }
    }
}

nonisolated final class FileShareServer: @unchecked Sendable {
    static let defaultPort = 7321
    static let defaultMaxAttempts = 50

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private let threadPool: NIOThreadPool
    private let fileIO: NonBlockingFileIO
    private var channel: Channel?

    private(set) var boundHost: String = "0.0.0.0"
    private(set) var boundPort: Int = 0

    var isRunning: Bool { channel != nil }

    init() {
        let pool = NIOThreadPool(numberOfThreads: 6)
        pool.start()
        self.threadPool = pool
        self.fileIO = NonBlockingFileIO(threadPool: pool)
    }

    deinit {
        try? group.syncShutdownGracefully()
        try? threadPool.syncShutdownGracefully()
    }

    func start(rootURL: URL,
               host: String = "0.0.0.0",
               preferredPort: Int = FileShareServer.defaultPort,
               maxAttempts: Int = FileShareServer.defaultMaxAttempts) async throws {
        guard channel == nil else { throw FileShareError.alreadyRunning }
        let normalizedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let bootstrap = makeBootstrap(rootURL: normalizedRoot)

        for attempt in 0..<maxAttempts {
            let port = preferredPort + attempt
            do {
                let ch = try await bootstrap.bind(host: host, port: port).asyncValue()
                self.channel = ch
                self.boundHost = host
                self.boundPort = port
                return
            } catch {
                // port in use (or transient bind error) — try the next port
            }
        }
        throw FileShareError.noPortAvailable(first: preferredPort, attempted: maxAttempts)
    }

    func stop() async {
        if let ch = channel {
            channel = nil
            try? await ch.close().asyncValue()
        }
    }

    private func makeBootstrap(rootURL: URL) -> ServerBootstrap {
        let fileIO = self.fileIO
        return ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPFileHandler(rootURL: rootURL, fileIO: fileIO))
                }
            }
    }
}

nonisolated extension EventLoopFuture {
    /// Bridge an `EventLoopFuture` to async/await.
    func asyncValue() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            whenComplete { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
