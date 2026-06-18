import XCTest
@testable import Apricot

final class ApricotTests: XCTestCase {
    func testSanity() {
        XCTAssertEqual(1 + 1, 2)
    }

    // MARK: - MimeTypeMap

    func testMimeTypeKnownExtensions() {
        XCTAssertEqual(MimeTypeMap.contentType(forPathExtension: "html"), "text/html; charset=utf-8")
        XCTAssertEqual(MimeTypeMap.contentType(forPathExtension: "PNG"), "image/png")
        XCTAssertEqual(MimeTypeMap.contentType(forPathExtension: "pdf"), "application/pdf")
    }

    func testMimeTypeUnknownIsOctetStream() {
        XCTAssertEqual(MimeTypeMap.contentType(forPathExtension: "zzz"), "application/octet-stream")
        XCTAssertEqual(MimeTypeMap.contentType(forPathExtension: ""), "application/octet-stream")
    }

    // MARK: - PathResolver

    func testPathResolverAllowsRoot() {
        let root = URL(fileURLWithPath: "/tmp/sharelocal_root")
        let path = PathResolver.containedAbsolutePath(relativePath: "/", root: root)
        XCTAssertEqual(path, "/tmp/sharelocal_root")
    }

    func testPathResolverAllowsSubpath() {
        let root = URL(fileURLWithPath: "/tmp/sharelocal_root")
        let path = PathResolver.containedAbsolutePath(relativePath: "/a/b.txt", root: root)
        XCTAssertEqual(path, "/tmp/sharelocal_root/a/b.txt")
    }

    func testPathResolverDecodesPercentEncoding() {
        let root = URL(fileURLWithPath: "/tmp/sharelocal_root")
        let path = PathResolver.containedAbsolutePath(relativePath: "/%61/%62.txt", root: root)
        XCTAssertEqual(path, "/tmp/sharelocal_root/a/b.txt")
    }

    func testPathResolverRejectsTraversal() {
        let root = URL(fileURLWithPath: "/tmp/sharelocal_root")
        XCTAssertNil(PathResolver.containedAbsolutePath(relativePath: "/../etc/passwd", root: root))
        XCTAssertNil(PathResolver.containedAbsolutePath(relativePath: "/a/../../etc/passwd", root: root))
        XCTAssertNil(PathResolver.containedAbsolutePath(relativePath: "/%2e%2e/secret", root: root))
    }

    func testPathResolverStripsQueryAndFragment() {
        let root = URL(fileURLWithPath: "/tmp/sharelocal_root")
        let path = PathResolver.containedAbsolutePath(relativePath: "/a.txt?x=1#frag", root: root)
        XCTAssertEqual(path, "/tmp/sharelocal_root/a.txt")
    }

    // MARK: - RangeParser

    func testRangeParserValid() {
        XCTAssertEqual(RangeParser.parse("bytes=0-99", total: 100)?.start, 0)
        XCTAssertEqual(RangeParser.parse("bytes=0-99", total: 100)?.end, 99)
        XCTAssertEqual(RangeParser.parse("bytes=10-19", total: 100)?.start, 10)
        XCTAssertEqual(RangeParser.parse("bytes=10-19", total: 100)?.end, 19)
    }

    func testRangeParserInvalid() {
        XCTAssertNil(RangeParser.parse("", total: 100))
        XCTAssertNil(RangeParser.parse("bytes=abc-def", total: 100))
        XCTAssertNil(RangeParser.parse("bytes=50-10", total: 100))
        XCTAssertNil(RangeParser.parse("bytes=0-100", total: 100))
    }

    // MARK: - DirectoryIndex

    private func entry(_ name: String, isDir: Bool = false, size: Int64 = 0) -> DirectoryEntry {
        DirectoryEntry(name: name, isDirectory: isDir, size: size,
                       modificationDate: Date(timeIntervalSince1970: 0))
    }

    func testDirectoryIndexEscapesNames() {
        let html = DirectoryIndex.html(title: "t",
                                       entries: [entry("<b>&x</b>")],
                                       requestPath: "/")
        XCTAssertTrue(html.contains("&lt;b&gt;&amp;x&lt;/b&gt;"))
        XCTAssertFalse(html.contains("<b>&x</b>"))
    }

    func testDirectoryIndexParentLinkOnlyForNonRoot() {
        let withParent = DirectoryIndex.html(title: "t", entries: [], requestPath: "/sub/")
        let atRoot = DirectoryIndex.html(title: "t", entries: [], requestPath: "/")
        XCTAssertTrue(withParent.contains("href=\"../\""))
        XCTAssertFalse(atRoot.contains("href=\"../\""))
    }

    func testDirectoryIndexSortsDirsFirstThenAlpha() {
        let entries = [entry("zeta.txt"), entry("Alpha", isDir: true), entry("beta.txt"), entry("Gamma", isDir: true)]
        let html = DirectoryIndex.html(title: "t", entries: entries, requestPath: "/")
        let alphaRange = html.range(of: "Alpha/")
        let gammaRange = html.range(of: "Gamma/")
        let betaRange = html.range(of: "beta.txt")
        let zetaRange = html.range(of: "zeta.txt")
        XCTAssertNotNil(alphaRange); XCTAssertNotNil(gammaRange)
        XCTAssertNotNil(betaRange); XCTAssertNotNil(zetaRange)
        XCTAssertLessThan(alphaRange!.lowerBound, gammaRange!.lowerBound)
        XCTAssertLessThan(gammaRange!.lowerBound, betaRange!.lowerBound)
        XCTAssertLessThan(betaRange!.lowerBound, zetaRange!.lowerBound)
    }

    func testHumanReadable() {
        XCTAssertEqual(DirectoryIndex.humanReadable(0), "0 B")
        XCTAssertEqual(DirectoryIndex.humanReadable(1023), "1023 B")
        XCTAssertEqual(DirectoryIndex.humanReadable(2048), "2.0 KB")
    }

    // MARK: - LocalNetwork

    func testBestIPv4PrefersEnInterface() {
        let interfaces = [
            LocalNetwork.Interface(name: "en0", address: "192.168.1.20"),
            LocalNetwork.Interface(name: "bridge100", address: "10.0.0.5"),
        ]
        XCTAssertEqual(LocalNetwork.bestIPv4(from: interfaces), "192.168.1.20")
    }

    func testBestIPv4ExcludesLoopback() {
        let interfaces = [
            LocalNetwork.Interface(name: "lo0", address: "127.0.0.1"),
            LocalNetwork.Interface(name: "en0", address: "192.168.1.20"),
        ]
        XCTAssertEqual(LocalNetwork.bestIPv4(from: interfaces), "192.168.1.20")
    }

    func testBestIPv4FallsBackToFirstNonLoopback() {
        let interfaces = [
            LocalNetwork.Interface(name: "lo0", address: "127.0.0.1"),
            LocalNetwork.Interface(name: "utun0", address: "10.0.0.9"),
        ]
        XCTAssertEqual(LocalNetwork.bestIPv4(from: interfaces), "10.0.0.9")
    }

    func testBestIPv4EmptyReturnsNil() {
        XCTAssertNil(LocalNetwork.bestIPv4(from: []))
    }
}
