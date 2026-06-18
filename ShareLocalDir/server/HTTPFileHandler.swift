import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

nonisolated final class HTTPFileHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let rootURL: URL
    private let fileIO: NonBlockingFileIO
    private var pendingHead: HTTPRequestHead?

    init(rootURL: URL, fileIO: NonBlockingFileIO) {
        self.rootURL = rootURL
        self.fileIO = fileIO
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.pendingHead = head
        case .body:
            break
        case .end:
            handle(context: context)
        }
    }

    func channelUnregistered(context: ChannelHandlerContext) {
        pendingHead = nil
    }

    private func handle(context: ChannelHandlerContext) {
        guard let head = pendingHead else {
            respondStatus(context, status: .badRequest)
            return
        }
        pendingHead = nil

        guard head.method == .GET else {
            respondStatus(context, status: .methodNotAllowed, extraHeaders: ["Allow": "GET"])
            return
        }

        switch PathResolver.resolve(relativePath: head.uri, root: rootURL) {
        case .failure(.forbidden):
            respondStatus(context, status: .forbidden)
        case .failure(.notFound):
            respondStatus(context, status: .notFound)
        case .success(let url):
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                serveDirectory(context: context, head: head, url: url)
            } else {
                serveFile(context: context, head: head, url: url)
            }
        }
    }

    // MARK: Directory listing

    private func serveDirectory(context: ChannelHandlerContext, head: HTTPRequestHead, url: URL) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            respondStatus(context, status: .forbidden)
            return
        }

        var entries: [DirectoryEntry] = []
        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            entries.append(DirectoryEntry(
                name: item.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modificationDate: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            ))
        }

        let title = rootURL.path == url.path ? "/" : url.lastPathComponent
        let body = DirectoryIndex.html(title: title, entries: entries, requestPath: head.uri)
        let bytes = Array(body.utf8)
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(bytes.count)")
        respond(context, status: .ok, headers: headers, body: buffer)
    }

    // MARK: File serving (streamed, with Range)

    private func serveFile(context: ChannelHandlerContext, head: HTTPRequestHead, url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let total = (attrs[.size] as? NSNumber)?.int64Value else {
            respondStatus(context, status: .notFound)
            return
        }

        let range = RangeParser.parse(head.headers.first(name: "Range") ?? "", total: total)
        let start: Int64 = range?.start ?? 0
        let endInclusive: Int64 = range?.end ?? (total - 1)
        let length = Int(endInclusive - start + 1)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: MimeTypeMap.contentType(for: url))
        headers.add(name: "Content-Length", value: "\(length)")
        headers.add(name: "Accept-Ranges", value: "bytes")
        if range != nil {
            headers.add(name: "Content-Range", value: "bytes \(start)-\(endInclusive)/\(total)")
        }
        let status: HTTPResponseStatus = range == nil ? .ok : .partialContent
        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)

        let allocator = context.channel.allocator
        let eventLoop = context.eventLoop
        let fileIO = self.fileIO
        let owner = self

        fileIO.openFile(path: url.path, eventLoop: eventLoop)
            .flatMap { (handle, _) -> EventLoopFuture<Void> in
                context.write(owner.wrapOutboundOut(.head(responseHead))).flatMap { _ -> EventLoopFuture<Void> in
                    fileIO.readChunked(
                        fileHandle: handle,
                        fromOffset: start,
                        byteCount: length,
                        allocator: allocator,
                        eventLoop: eventLoop
                    ) { chunk -> EventLoopFuture<Void> in
                        context.writeAndFlush(owner.wrapOutboundOut(.body(.byteBuffer(chunk))))
                    }
                }.flatMap { _ -> EventLoopFuture<Void> in
                    context.writeAndFlush(owner.wrapOutboundOut(.end(nil)))
                }.always { _ in
                    try? handle.close()
                    context.close(promise: nil)
                }
            }
            .whenFailure { _ in
                // Only reached if openFile itself failed (we had not written any head yet).
                owner.respondStatus(context, status: .notFound)
            }
    }

    // MARK: Response helpers

    private func respond(_ context: ChannelHandlerContext,
                         status: HTTPResponseStatus,
                         headers: HTTPHeaders,
                         body: ByteBuffer) {
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }

    private func respondStatus(_ context: ChannelHandlerContext,
                               status: HTTPResponseStatus,
                               extraHeaders: [String: String] = [:]) {
        var headers = HTTPHeaders()
        for (k, v) in extraHeaders { headers.add(name: k, value: v) }
        let text = "\(status.code) \(status.reasonPhrase)\n"
        var buf = context.channel.allocator.buffer(capacity: text.utf8.count)
        buf.writeString(text)
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(text.utf8.count)")
        respond(context, status: status, headers: headers, body: buf)
    }
}
