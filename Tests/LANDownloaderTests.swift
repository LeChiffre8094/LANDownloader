import XCTest
@testable import LANDownloader

final class LANDownloaderTests: XCTestCase {
    let root = URL(string: "http://192.168.1.2:8080/share/")!
    func testAllRequestedVideoExtensions() {
        for ext in "mp4 mkv mov m4v avi ts m2ts webm flv wmv mpg mpeg 3gp".split(separator: " ") {
            XCTAssertEqual(FileCategory.classify("片段.\(ext.uppercased())"), .video)
        }
        XCTAssertEqual(FileCategory.classify("photo.HEIC"), .image)
        XCTAssertEqual(FileCategory.classify("sound.FLAC"), .audio)
        XCTAssertEqual(FileCategory.classify("report.pdf"), .document)
        XCTAssertEqual(FileCategory.classify("backup.tar.gz"), .archive)
        XCTAssertEqual(FileCategory.classify("unknown.bin"), .other)
    }
    func testRejectUnsafeAndNonChildLinks() {
        for href in ["../", "../../secret", "https://evil.test/a.mp4", "//evil.test/a.mp4", "javascript:alert(1)", "?sort=name", "#anchor", "%2e%2e/secret", "a%2Fb.mp4", "a%5Cb.mp4", "a%00b", "sub/child.mp4", "/share2/file.mp4", "http://192.168.1.2:8081/share/a.mp4", "http://user:pass@192.168.1.2:8080/share/a.mp4"] {
            XCTAssertNil(DirectoryParser.childURL(href, directory: root, root: root), href)
        }
    }
    func testEncodedNamesAndSubdirectory() {
        let url = DirectoryParser.childURL("%E4%B8%AD%E6%96%87%20%23%26%25%2B.mp4", directory: root, root: root)
        XCTAssertEqual(url?.lastPathComponent, "中文 #&%+.mp4")
        XCTAssertEqual(url?.absoluteString, "http://192.168.1.2:8080/share/%E4%B8%AD%E6%96%87%20%23%26%25%2B.mp4")
        XCTAssertNotNil(DirectoryParser.childURL("folder/", directory: root, root: root))
        XCTAssertFalse(DirectoryParser.isWithinRoot(URL(string: "http://192.168.1.2:8080/share2/")!, root: root))
    }
    func testNativeCaddyJSONAndLargeFiles() throws {
        let data = Data("""
        [{"name":"large.mkv","url":"./large.mkv","size":9000000000,"is_dir":false,"mod_time":"2026-10-13T00:00:00Z"},
         {"name":"sub/","url":"./sub/","size":0,"is_dir":true,"mod_time":"2026-10-13T00:00:00Z"},
         {"name":"external","url":"https://evil.test/file","size":4,"is_dir":false}]
        """.utf8)
        let files = try DirectoryParser.parse(data, mime: "application/json", directory: root, root: root)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertEqual(files[1].size, 9_000_000_000)
        XCTAssertTrue(files[1].url.hasPrefix(root.absoluteString))
    }
    func testHTMLDoesNotTrustBaseScriptsOrNavigation() throws {
        let data = Data("""
        <html><head><base href="https://evil.test/"></head><body>
        <script>location='https://evil.test/'</script><a href="unrelated">nav</a>
        <table><tbody><tr><td><a href="../">up</a></td></tr>
        <tr><td><a href="./a%26b.mp4">a&amp;b.mp4</a></td></tr>
        <tr><td><a href="javascript:alert(1)">bad</a></td></tr>
        <tr><td><a href="./sub/">folder</a></td></tr></tbody></table></body></html>
        """.utf8)
        let files = try DirectoryParser.parse(data, mime: "text/html", directory: root, root: root)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[1].name, "a&b.mp4")
        XCTAssertEqual(files[1].size, -1)
        XCTAssertTrue(files.allSatisfy { $0.url.hasPrefix(root.absoluteString) })
    }
    func testSameFilenameAcrossServersHasDifferentIdentity() {
        let a = VideoFile(path: "/file.mp4", name: "file.mp4", size: 2, url: "http://a:8080/file.mp4")
        let b = VideoFile(path: "/file.mp4", name: "file.mp4", size: 2, url: "http://b:8080/file.mp4")
        XCTAssertNotEqual(a.id, b.id)
    }
    func testOriginalFilenameAndCollisionWithoutOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for number in 0...2 {
            let temp = directory.appendingPathComponent("temp-\(number)")
            try Data("payload-\(number)".utf8).write(to: temp)
            let result = try FileDestination.move(temp, to: directory, name: "中文片段.mkv")
            XCTAssertEqual(result.lastPathComponent, number == 0 ? "中文片段.mkv" : "中文片段 (\(number)).mkv")
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("中文片段.mkv"), encoding: .utf8), "payload-0")
    }
    func testVersionOneRecordStillDecodes() throws {
        let data = Data("""
        [{"id":"folder/a.mp4","path":"folder/a.mp4","name":"a.mp4","url":"http://192.168.1.2:8080/folder/a.mp4","size":9000000000,"bytes":5000000000,"status":"downloading"}]
        """.utf8)
        let records = try JSONDecoder().decode([DownloadRecord].self, from: data)
        XCTAssertEqual(records[0].id, "folder/a.mp4")
        XCTAssertEqual(records[0].bytes, 5_000_000_000)
        XCTAssertNil(records[0].localName)
    }
    func testServerAddressValidation() throws {
        XCTAssertEqual(try Server.normalizedAddress("192.168.1.2:8080"), "http://192.168.1.2:8080/")
        XCTAssertEqual(try Server.normalizedAddress("https://example.test/share"), "https://example.test/share/")
        for bad in ["", "file:///etc", "http://user:pass@host", "http://host/?token=secret", "http://host:70000"] {
            XCTAssertThrowsError(try Server.normalizedAddress(bad), bad)
        }
    }
}
