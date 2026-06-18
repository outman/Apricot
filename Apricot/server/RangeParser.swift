import Foundation

nonisolated enum RangeParser {
    struct Range: Equatable {
        let start: Int64
        let end: Int64
    }

    /// Parse a `Range: bytes=start-end` header into inclusive bounds, or nil if absent/invalid.
    static func parse(_ header: String, total: Int64) -> Range? {
        guard header.hasPrefix("bytes=") else { return nil }
        let body = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        let parts = body.split(separator: "-").map(String.init)
        guard parts.count == 2,
              let start = Int64(parts[0]),
              let end = Int64(parts[1]) else { return nil }
        guard start >= 0, end < total, start <= end else { return nil }
        return Range(start: start, end: end)
    }
}
