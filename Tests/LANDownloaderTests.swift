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
        XCTAssertNil(records[0].directoryBookmark)
    }
    func testServerAddressValidation() throws {
        XCTAssertEqual(try Server.normalizedAddress("192.168.1.2:8080"), "http://192.168.1.2:8080/")
        XCTAssertEqual(try Server.normalizedAddress("https://example.test/share"), "https://example.test/share/")
        for bad in ["", "file:///etc", "http://user:pass@host", "http://host/?token=secret", "http://host:70000"] {
            XCTAssertThrowsError(try Server.normalizedAddress(bad), bad)
        }
    }
    private func withFileFixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("目标目录", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, target)
    }
    func testRenamePreservesContentAndRejectsCollision() throws {
        try withFileFixture { root, _ in
            let source = root.appendingPathComponent("原名.mp4")
            try Data("original".utf8).write(to: source)
            let renamed = try LocalFileOperations.rename(source, to: "新名字 #%.mp4")
            XCTAssertEqual(try Data(contentsOf: renamed), Data("original".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            let existing = root.appendingPathComponent("已有.mp4")
            try Data("keep".utf8).write(to: existing)
            XCTAssertThrowsError(try LocalFileOperations.rename(renamed, to: existing.lastPathComponent))
            XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        }
    }
    func testRenameRejectsPathTraversalAndEmptyNames() throws {
        for name in ["", "   ", ".", "..", "../other", "sub/file", "sub\\file", "bad\nname"] {
            XCTAssertThrowsError(try LocalFileOperations.validatedName(name), name)
        }
        XCTAssertEqual(try LocalFileOperations.validatedName("中文 #&%+.mkv"), "中文 #&%+.mkv")
    }
    func testCopyNumbersCollisionAndKeepsOriginal() throws {
        try withFileFixture { root, target in
            let source = root.appendingPathComponent("片段.mkv")
            try Data("source".utf8).write(to: source)
            let existing = target.appendingPathComponent("片段.mkv")
            try Data("keep".utf8).write(to: existing)
            let copied = try LocalFileOperations.transfer(source, to: target, moving: false)
            XCTAssertEqual(copied.lastPathComponent, "片段 (1).mkv")
            XCTAssertEqual(try Data(contentsOf: copied), Data("source".utf8))
            XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
            XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        }
    }
    func testMoveCompletesDestinationBeforeRemovingSource() throws {
        try withFileFixture { root, target in
            let source = root.appendingPathComponent("move.mp4")
            let payload = Data(repeating: 17, count: 10000)
            try payload.write(to: source)
            let moved = try LocalFileOperations.transfer(source, to: target, moving: true)
            XCTAssertEqual(try Data(contentsOf: moved), payload)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }
    func testInvalidMoveDestinationKeepsSource() throws {
        try withFileFixture { root, _ in
            let source = root.appendingPathComponent("stay.mp4")
            try Data("preserve".utf8).write(to: source)
            XCTAssertThrowsError(try LocalFileOperations.transfer(source, to: root.appendingPathComponent("missing"), moving: true))
            XCTAssertThrowsError(try LocalFileOperations.transfer(source, to: root, moving: true))
            XCTAssertEqual(try Data(contentsOf: source), Data("preserve".utf8))
        }
    }
    func testDeleteOnlyRemovesSelectedFile() throws {
        try withFileFixture { root, _ in
            let source = root.appendingPathComponent("remove.mp4")
            let other = root.appendingPathComponent("keep.mp4")
            try Data("remove".utf8).write(to: source)
            try Data("keep".utf8).write(to: other)
            try LocalFileOperations.delete(source)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try Data(contentsOf: other), Data("keep".utf8))
        }
    }

}
