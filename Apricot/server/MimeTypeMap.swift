import Foundation

nonisolated enum MimeTypeMap {
    private static let map: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "application/javascript",
        "json": "application/json",
        "txt": "text/plain; charset=utf-8",
        "md": "text/markdown; charset=utf-8",
        "xml": "application/xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "svg": "image/svg+xml",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "bmp": "image/bmp",
        "pdf": "application/pdf",
        "zip": "application/zip",
        "gz": "application/gzip",
        "tar": "application/x-tar",
        "7z": "application/x-7z-compressed",
        "mp4": "video/mp4",
        "mov": "video/quicktime",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "m4a": "audio/mp4",
    ]

    static func contentType(forPathExtension ext: String) -> String {
        map[ext.lowercased()] ?? "application/octet-stream"
    }

    static func contentType(for url: URL) -> String {
        contentType(forPathExtension: url.pathExtension)
    }
}
