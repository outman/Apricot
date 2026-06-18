import Foundation

nonisolated struct DirectoryEntry: Equatable {
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date
}

nonisolated enum DirectoryIndex {
    static func html(title: String, entries: [DirectoryEntry], requestPath: String) -> String {
        var out = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        body{font-family:-apple-system,system-ui,sans-serif;max-width:920px;margin:24px auto;padding:0 16px;color:#222}
        h1{font-size:18px;font-weight:600;word-break:break-all}
        table{width:100%;border-collapse:collapse}
        th,td{text-align:left;padding:8px;border-bottom:1px solid #eee;font-size:14px}
        th{color:#888;font-weight:500}
        a{color:#0a66c2;text-decoration:none}
        a:hover{text-decoration:underline}
        .meta{color:#888;text-align:right;white-space:nowrap}
        </style></head><body>
        <h1>\(escape(title))</h1>
        <table><thead><tr><th>名称</th><th class="meta">大小</th><th class="meta">修改时间</th></tr></thead><tbody>

        """
        if requestPath != "/" {
            out += "<tr><td colspan=\"3\"><a href=\"../\">../</a></td></tr>\n"
        }

        let sorted = entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        for e in sorted {
            let display = escape(e.name) + (e.isDirectory ? "/" : "")
            let href = escapePathComponent(e.name) + (e.isDirectory ? "/" : "")
            let size = e.isDirectory ? "-" : humanReadable(e.size)
            let date = df.string(from: e.modificationDate)
            out += "<tr><td><a href=\"\(href)\">\(display)</a></td><td class=\"meta\">\(size)</td><td class=\"meta\">\(escape(date))</td></tr>\n"
        }

        out += "</tbody></table></body></html>\n"
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func escapePathComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    static func humanReadable(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[idx])
    }
}
