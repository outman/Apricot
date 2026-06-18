import Foundation

nonisolated enum PathResolver {
    enum Error: Swift.Error, Equatable {
        case forbidden
        case notFound
    }

    /// Pure: resolve `relativePath` (an HTTP request URI) against `root` and verify the result
    /// stays inside `root`. Returns the standardized absolute path on success, nil on escape.
    static func containedAbsolutePath(relativePath uri: String, root: URL) -> String? {
        // strip query and fragment
        var pathOnly = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        pathOnly = pathOnly.split(separator: "#", maxSplits: 1).first.map(String.init) ?? pathOnly

        // percent-decode once (catches %2e%2e)
        guard let decoded = pathOnly.removingPercentEncoding else { return nil }

        let rootStd = root.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPrefix = rootStd.hasSuffix("/") ? rootStd : rootStd + "/"

        // drop a leading "/" so we append relative segments
        let relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded

        let candidate = URL(fileURLWithPath: rootStd, isDirectory: true)
            .appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        let isRoot = candidate == rootStd
        let isUnder = candidate.hasPrefix(rootPrefix)
        guard isRoot || isUnder else { return nil }
        return candidate
    }

    /// Filesystem-aware resolve. `.forbidden` if the path escapes root, `.notFound` if it
    /// doesn't exist.
    static func resolve(relativePath uri: String, root: URL) -> Result<URL, Error> {
        guard let path = containedAbsolutePath(relativePath: uri, root: root) else {
            return .failure(.forbidden)
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(.notFound)
        }
        return .success(URL(fileURLWithPath: path))
    }
}
