import Foundation

enum BookmarkStore {
    private static let key = "selectedFolderBookmark"

    static func save(url: URL) {
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            clear()
            return nil
        }
        if stale { save(url: url) }
        return url
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
