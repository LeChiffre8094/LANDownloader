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
            XCTAssertEqual(result.lastPathComponent, number == 0 ? "中文片段.mkv" : "中文片段(\(number + 1)).mkv")
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
            XCTAssertEqual(copied.lastPathComponent, "片段(2).mkv")
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


    private func queueRecord(_ id: String, _ status: String, url: String = "http://192.168.1.2:8080/file.mp4") -> DownloadRecord {
        DownloadRecord(id: id, path: id + ".mp4", name: id + ".mp4", url: url, size: 100, bytes: 0, status: status, localName: nil, error: nil)
    }
    func testWholeServerBatchSubmittedBeforeFirstCompletion() {
        let records = [queueRecord("a", "queued"), queueRecord("b", "queued"), queueRecord("c", "queued")]
        XCTAssertEqual(SerialDownloadQueue.batchIDs(records: records, restoring: false, outstanding: false), ["a", "b", "c"])
    }
    func testExistingBatchAcceptsNewFilesWithoutWaitingForCompletion() {
        let records = [queueRecord("a", "downloading"), queueRecord("b", "scheduled"), queueRecord("c", "queued")]
        XCTAssertEqual(SerialDownloadQueue.batchIDs(records: records, restoring: false, outstanding: false), ["c"])
    }
    func testDifferentServersWaitForExistingBatch() {
        let other = "http://192.168.1.3:8080/file.mp4"
        var records = [queueRecord("a", "scheduled"), queueRecord("b", "queued", url: other)]
        XCTAssertTrue(SerialDownloadQueue.batchIDs(records: records, restoring: false, outstanding: false).isEmpty)
        records[0].status = "completed"
        XCTAssertEqual(SerialDownloadQueue.batchIDs(records: records, restoring: false, outstanding: false), ["b"])
    }
    func testBatchWaitsForRestorationAndCancellation() {
        let records = [queueRecord("a", "queued")]
        XCTAssertTrue(SerialDownloadQueue.batchIDs(records: records, restoring: true, outstanding: false).isEmpty)
        XCTAssertTrue(SerialDownloadQueue.batchIDs(records: records, restoring: false, outstanding: true).isEmpty)
        for state in ["pausing", "cancelling"] {
            XCTAssertTrue(SerialDownloadQueue.batchIDs(records: [queueRecord("old", state)] + records, restoring: false, outstanding: false).isEmpty)
        }
    }
    func testOriginIncludesSchemeAndPort() {
        XCTAssertEqual(SerialDownloadQueue.origin("http://EXAMPLE.com/a"), SerialDownloadQueue.origin("http://example.com:80/b"))
        XCTAssertNotEqual(SerialDownloadQueue.origin("http://example.com:80/a"), SerialDownloadQueue.origin("http://example.com:8080/b"))
        XCTAssertNotEqual(SerialDownloadQueue.origin("http://example.com/a"), SerialDownloadQueue.origin("https://example.com/b"))
        XCTAssertNil(SerialDownloadQueue.origin("file:///tmp/a"))
    }
    func testSubmittedRecordsSurvivePersistenceWithoutResubmission() throws {
        let original = [queueRecord("a", "scheduled"), queueRecord("b", "paused"), queueRecord("c", "queued")]
        let restored = try JSONDecoder().decode([DownloadRecord].self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.map { $0.status }, ["scheduled", "paused", "queued"])
        XCTAssertEqual(SerialDownloadQueue.batchIDs(records: restored, restoring: false, outstanding: false), ["c"])
    }

    private func browseEntry(_ url: URL, folder: Bool = false) -> VideoFile {
        VideoFile(path: url.path, name: url.lastPathComponent, size: folder ? 0 : 10, url: url.absoluteString, isDirectory: folder)
    }
    func testRecursiveListingIncludesAllLevelsAndSameNames() async throws {
        let child = root.appendingPathComponent("3", isDirectory: true)
        let deep = child.appendingPathComponent("4", isDirectory: true)
        let result = try await DirectoryBrowser().loadRecursively(directory: root, root: root) { directory, _ in
            if directory == self.root { return [self.browseEntry(self.root.appendingPathComponent("same.mp4")), self.browseEntry(child, folder: true)] }
            if directory == child { return [self.browseEntry(child.appendingPathComponent("same.mp4")), self.browseEntry(deep, folder: true)] }
            return [self.browseEntry(deep.appendingPathComponent("中文 #%.mkv"))]
        }
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Set(result.map { $0.id }).count, 3)
        XCTAssertEqual(result.filter { $0.name == "same.mp4" }.count, 2)
        XCTAssertFalse(result.contains { $0.isDirectory })
    }
    func testRecursiveListingRejectsExternalParentAndDuplicateEntries() async throws {
        let file = browseEntry(root.appendingPathComponent("ok.mp4"))
        let result = try await DirectoryBrowser().loadRecursively(directory: root, root: root) { _, _ in
            [file, file, self.browseEntry(self.root, folder: true), self.browseEntry(URL(string: "http://evil.test/a/")!, folder: true)]
        }
        XCTAssertEqual(result.map { $0.name }, ["ok.mp4"])
    }
    func testRecursiveFailureDoesNotReturnPartialSuccess() async {
        do {
            _ = try await DirectoryBrowser().loadRecursively(directory: root, root: root) { directory, _ in
                if directory == self.root { return [self.browseEntry(self.root.appendingPathComponent("ok.txt")), self.browseEntry(self.root.appendingPathComponent("bad", isDirectory: true), folder: true)] }
                throw LANError(message: "fixture failure")
            }
            XCTFail("A failed subdirectory must not look like a complete scan")
        } catch { XCTAssertTrue(error.localizedDescription.contains("汇总未完成")) }
    }
    func testRecursiveScanStopsAtDepthLimit() async {
        do {
            _ = try await DirectoryBrowser().loadRecursively(directory: root, root: root) { directory, _ in
                [self.browseEntry(directory.appendingPathComponent("loop", isDirectory: true), folder: true)]
            }
            XCTFail("An expanding symlink-like hierarchy must be bounded")
        } catch { XCTAssertTrue(error.localizedDescription.contains("层级")) }
    }
    func testMKVAndNonNativeContainersChooseFFmpeg() {
        for name in ["movie.MKV", "movie.avi", "movie.ts", "movie.webm", "movie.wmv", "movie.flv"] {
            XCTAssertEqual(PlaybackEngine.initial(for: name), .ffmpeg)
        }
        XCTAssertEqual(PlaybackEngine.initial(for: "movie.MP4"), .native)
    }
    func testPlaybackFallbackTerminatesAfterSoftwareAttempt() {
        XCTAssertEqual(PlaybackEngine.native.fallback, .ffmpeg)
        XCTAssertEqual(PlaybackEngine.ffmpeg.fallback, .software)
        XCTAssertNil(PlaybackEngine.software.fallback)
    }

    func testNumberedDownloadSkipsExistingNamesAndPreservesExtension() throws {
        try withFileFixture { root, _ in
            for name in ["1.MP4", "1(2).MP4", "1(3).MP4"] {
                try Data(name.utf8).write(to: root.appendingPathComponent(name))
            }
            let source = root.appendingPathComponent("incoming.tmp")
            try Data("new content".utf8).write(to: source)
            let result = try FileDestination.move(source, to: root, name: "1.MP4")
            XCTAssertEqual(result.lastPathComponent, "1(4).MP4")
            XCTAssertEqual(try Data(contentsOf: result), Data("new content".utf8))
            for name in ["1.MP4", "1(2).MP4", "1(3).MP4"] {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data(name.utf8))
            }
        }
    }
}
