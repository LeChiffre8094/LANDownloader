import Foundation
import Combine
import UIKit
import CryptoKit

// v0.1 background session identifier and AppDelegate event bridge deliberately retained.
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var restoring = true
    @Published var notice: String?
    @Published private(set) var fileOperationID: String?
    private let fileQueue = DispatchQueue(label: "LANDownloader.fileOperations", qos: .userInitiated)
    private var session: URLSession!
    private var backgroundCompletion: (() -> Void)?
    private let storeQueue = DispatchQueue(label: "LANDownloader.store")
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var retiringTasks = Set<Int>()
    private var lastPersist = Date.distantPast
    private let reserve: Int64 = 200 * 1024 * 1024
    private var supportURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    private var stateURL: URL { supportURL.appendingPathComponent("downloads.json") }
    private var documentURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private func resumeURL(_ id: String) -> URL {
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return supportURL.appendingPathComponent("resume-\(key).data")
    }
    private override init() {
        super.init()
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: documentURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stateURL) {
            do { records = try JSONDecoder().decode([DownloadRecord].self, from: data) }
            catch {
                let backup = supportURL.appendingPathComponent("downloads-unreadable-\(UUID().uuidString).json")
                try? data.write(to: backup, options: .atomic)
                notice = "旧任务记录无法读取，已尝试备份记录；原文件仍保留在文件 App。"
            }
        }
        let config = URLSessionConfiguration.background(withIdentifier: "com.lantransfer.downloader.background.v1")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = false
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 1
        // Server-side queuing can withhold response headers while a large file finishes.
        config.timeoutIntervalForRequest = 7 * 24 * 60 * 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        config.httpShouldUsePipelining = false // Plain HTTP Caddy uses one request at a time on this connection.
        // Serial main delegate queue keeps task state and UI mutations in one ordering.
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        restoreTasks()
    }
    func setBackgroundCompletion(_ handler: @escaping () -> Void) {
        DispatchQueue.main.async { self.backgroundCompletion = handler }
    }
    private func persist() {
        let snapshot = records
        let url = stateURL
        storeQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch { DispatchQueue.main.async { self.notice = "任务记录保存失败：\(error.localizedDescription)" } }
        }
    }
    private func retire(_ task: URLSessionTask) {
        guard task.state != .completed else { return }
        retiringTasks.insert(task.taskIdentifier)
        task.cancel()
    }
    private func restoreTasks() {
        session.getAllTasks { existing in
            DispatchQueue.main.async {
                for task in existing {
                    guard let download = task as? URLSessionDownloadTask, let id = task.taskDescription,
                          let i = self.records.firstIndex(where: { $0.id == id }) else { self.retire(task); continue }
                    if ["completed", "cancelled", "cancelling", "failed"].contains(self.records[i].status) {
                        if self.records[i].status == "cancelling" { self.records[i].status = "cancelled" }
                        self.retire(task); continue
                    }
                    // A duplicate system task must never create a second active transfer.
                    if self.tasks[id] != nil { self.retire(task); continue }
                    self.tasks[id] = download
                    if ["paused", "pausing"].contains(self.records[i].status) {
                        self.records[i].status = "paused"
                        if task.state == .running { task.suspend() }
                    } else {
                        self.records[i].status = "scheduled"
                        if task.state == .suspended { self.persist(); self.resumeAfterPersist(download, id: id) }
                    }
                }
                for i in self.records.indices where ["scheduled", "downloading", "pausing", "cancelling"].contains(self.records[i].status) && self.tasks[self.records[i].id] == nil {
                    switch self.records[i].status {
                    case "cancelling": self.records[i].status = "cancelled"
                    case "pausing": self.records[i].status = "paused"
                    default: self.records[i].status = "queued"
                    }
                }
                self.restoring = false
                self.persist()
                self.startNextIfPossible()
            }
        }
    }
    private func startNextIfPossible() {
        // Submit the whole server batch while awake. Background completion callbacks
        // must not be required to launch each subsequent file in that batch.
        let ids = SerialDownloadQueue.batchIDs(records: records, restoring: restoring, outstanding: !retiringTasks.isEmpty)
        for id in ids {
            guard let i = records.firstIndex(where: { $0.id == id }) else { continue }
            if let task = tasks[id] {
                records[i].status = "scheduled"
                records[i].error = nil
                persist()
                resumeAfterPersist(task, id: id)
            } else { start(records[i], resume: true) }
        }
    }
    private func resumeAfterPersist(_ task: URLSessionDownloadTask, id: String) {
        storeQueue.async { DispatchQueue.main.async {
            if self.tasks[id]?.taskIdentifier == task.taskIdentifier && ["scheduled", "downloading"].contains(self.records.first(where: { $0.id == id })?.status ?? "") { task.resume() }
        } }
    }
    private func availableBytes() -> Int64? {
        if let values = try? documentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let value = values.volumeAvailableCapacityForImportantUsage { return value }
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: documentURL.path)
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value
    }
    private func saturatedAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let result = a.addingReportingOverflow(max(0, b))
        return result.overflow ? Int64.max : result.partialValue
    }
    private func checkCapacity(additional: Int64, excluding id: String? = nil, includeQueued: Bool = true) -> Bool {
        guard let available = availableBytes() else {
            notice = "无法读取设备可用空间，请稍后重试。"; return false
        }
        let remaining = records.filter { (["scheduled", "downloading"].contains($0.status) || (includeQueued && $0.status == "queued")) && $0.id != id }.reduce(reserve) {
            saturatedAdd($0, $1.size > 0 ? max(0, $1.size - $1.bytes) : 0)
        }
        guard saturatedAdd(remaining, additional) <= available else {
            notice = "可用空间不足（剩余 \(sizeString(available))），请清理空间后重试。"; return false
        }
        return true
    }
    @discardableResult
    func enqueue(_ files: [VideoFile]) -> Int {
        guard !restoring else { notice = "正在恢复后台任务，请稍候"; return 0 }
        let eligible = files.filter { !$0.isDirectory }
        var accepted: [VideoFile] = []
        var seen = Set<String>()
        for file in eligible {
            guard seen.insert(file.url).inserted,
                  SerialDownloadQueue.origin(file.url) != nil,
                  !records.contains(where: { $0.url == file.url && ["queued", "scheduled", "downloading", "pausing", "paused", "cancelling", "completed"].contains($0.status) }) else { continue }
            accepted.append(file)
        }
        let bytes = accepted.reduce(Int64(0)) { saturatedAdd($0, $1.size) }
        guard !accepted.isEmpty else { notice = "所选文件已有下载任务或已完成，可在下载页查看。"; return 0 }
        guard checkCapacity(additional: bytes) else { return 0 }
        for file in accepted {
            let record = DownloadRecord(id: UUID().uuidString, path: file.path, name: file.name,
                                        url: file.url, size: file.size, bytes: 0, status: "queued", localName: nil, error: nil)
            records.append(record)
        }
        persist()
        startNextIfPossible()
        return accepted.count
    }
    private func start(_ record: DownloadRecord, resume: Bool) {
        guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        guard let url = URL(string: record.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            records[i].status = "failed"; records[i].error = "无效下载地址"; persist(); startNextIfPossible(); return
        }
        let task: URLSessionDownloadTask
        if resume, let data = try? Data(contentsOf: resumeURL(record.id)) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: url)
            records[i].bytes = 0
        }
        records[i].status = "scheduled"
        records[i].error = nil
        task.taskDescription = record.id
        tasks[record.id] = task
        persist()
        resumeAfterPersist(task, id: record.id)
    }
    func retry(_ record: DownloadRecord, fromBeginning: Bool = false) {
        guard !restoring, let i = records.firstIndex(where: { $0.id == record.id }),
              ["paused", "failed", "interrupted", "cancelled"].contains(records[i].status) else { return }
        let current = records[i]
        let canResume = !fromBeginning && (tasks[record.id] != nil || FileManager.default.fileExists(atPath: resumeURL(record.id).path))
        guard checkCapacity(additional: max(0, current.size - (canResume ? current.bytes : 0)), excluding: record.id) else { return }
        if fromBeginning {
            if let oldTask = tasks.removeValue(forKey: record.id) { retire(oldTask) }
            try? FileManager.default.removeItem(at: resumeURL(record.id))
            records[i].bytes = 0
        }
        records[i].status = "queued"
        records[i].error = nil
        persist()
        startNextIfPossible()
    }
    func pause(_ record: DownloadRecord) {
        guard !restoring, let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        if records[i].status == "queued" { records[i].status = "paused"; persist(); startNextIfPossible(); return }
        guard let task = tasks[record.id], ["scheduled", "downloading"].contains(records[i].status) else { return }
        records[i].status = "pausing"
        try? FileManager.default.removeItem(at: resumeURL(record.id))
        persist()
        retiringTasks.insert(task.taskIdentifier)
        task.cancel(byProducingResumeData: { data in
            DispatchQueue.main.async {
                guard let i = self.records.firstIndex(where: { $0.id == record.id }), self.records[i].status == "pausing" else { return }
                if let data {
                    do { try data.write(to: self.resumeURL(record.id), options: .atomic) }
                    catch { self.records[i].error = "续传信息保存失败，继续时将重新下载。" }
                } else { self.records[i].error = "服务器未提供续传信息，继续时将重新下载。" }
                self.records[i].status = "paused"
                if self.tasks[record.id]?.taskIdentifier == task.taskIdentifier { self.tasks.removeValue(forKey: record.id) }
                self.persist()
                self.startNextIfPossible()
            }
        })
    }
    func cancel(_ record: DownloadRecord) {
        guard let i = records.firstIndex(where: { $0.id == record.id }), !["pausing", "completed"].contains(records[i].status) else { return }
        records[i].status = tasks[record.id] == nil ? "cancelled" : "cancelling"
        records[i].error = nil
        if let task = tasks[record.id] { retire(task) }
        try? FileManager.default.removeItem(at: resumeURL(record.id))
        persist()
        startNextIfPossible()
    }
    func remove(_ record: DownloadRecord) {
        guard fileOperationID != record.id else { return }
        guard !["downloading", "pausing", "cancelling"].contains(record.status) else { return }
        if let task = tasks.removeValue(forKey: record.id) { retire(task) }
        records.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: resumeURL(record.id))
        persist()
        startNextIfPossible()
    }
    func accessibleFile(_ record: DownloadRecord) throws -> LocalFileAccess {
        guard let current = records.first(where: { $0.id == record.id }), current.status == "completed",
              let name = current.localName else { throw LANError(message: "文件已被删除或不再可用。") }
        let folder: URL
        if let bookmark = current.directoryBookmark {
            var stale = false
            folder = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale {
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                let refreshed = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                if let i = records.firstIndex(where: { $0.id == record.id }) { records[i].directoryBookmark = refreshed; persist() }
            }
        } else { folder = documentURL }
        return try LocalFileAccess(folder: folder, name: name)
    }

    func renameFile(_ record: DownloadRecord, to name: String) {
        performFileOperation(record) { access in
            let destination = try LocalFileOperations.rename(access.url, to: name)
            return FileChange(name: destination.lastPathComponent, bookmark: record.directoryBookmark, deleted: false, message: nil)
        }
    }

    func transferFile(_ record: DownloadRecord, to folder: URL, moving: Bool) {
        // Acquire the picker grant before its delegate callback returns.
        let destinationAccess = ScopedDirectoryAccess(folder)
        performFileOperation(record) { access in
            // Create the bookmark before moving anything; a failed grant leaves the source untouched.
            let bookmark: Data?
            if moving { bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
            else { bookmark = nil }
            let destination = try LocalFileOperations.transfer(access.url, to: destinationAccess.url, moving: moving)
            if moving {
                return FileChange(name: destination.lastPathComponent, bookmark: bookmark, deleted: false, message: "已移动到所选文件夹。")
            }
            return FileChange(name: nil, bookmark: nil, deleted: false, message: "已复制到所选文件夹，原文件保留。")
        }
    }

    func deleteFile(_ record: DownloadRecord) {
        performFileOperation(record) { access in
            try LocalFileOperations.delete(access.url)
            return FileChange(name: nil, bookmark: nil, deleted: true, message: "文件及下载记录已删除。")
        }
    }

    private struct FileChange {
        let name: String?
        let bookmark: Data?
        let deleted: Bool
        let message: String?
    }
    private func performFileOperation(_ record: DownloadRecord, operation: @escaping (LocalFileAccess) throws -> FileChange) {
        guard fileOperationID == nil else { return }
        do {
            let access = try accessibleFile(record)
            fileOperationID = record.id
            fileQueue.async {
                let result = Result { try operation(access) }
                DispatchQueue.main.async {
                    self.fileOperationID = nil
                    switch result {
                    case .success(let change):
                        if let i = self.records.firstIndex(where: { $0.id == record.id }) {
                            if change.deleted {
                                self.records.remove(at: i)
                            } else if let name = change.name {
                                self.records[i].name = name
                                self.records[i].localName = name
                                self.records[i].directoryBookmark = change.bookmark
                                self.records[i].error = nil
                            }
                            self.persist()
                        }
                        if let message = change.message { self.notice = message }
                    case .failure(let error): self.notice = error.localizedDescription
                    }
                }
            }
        } catch { notice = error.localizedDescription }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, let i = records.firstIndex(where: { $0.id == id }),
              (tasks[id] == nil || tasks[id]?.taskIdentifier == downloadTask.taskIdentifier), ["scheduled", "downloading"].contains(records[i].status) else { return }
        tasks[id] = downloadTask
        records[i].status = "downloading"
        records[i].bytes = totalBytesWritten
        if totalBytesExpectedToWrite > 0 { records[i].size = totalBytesExpectedToWrite }
        if Date().timeIntervalSince(lastPersist) > 3 {
            lastPersist = Date()
            if !checkCapacity(additional: max(0, records[i].size - totalBytesWritten), excluding: id, includeQueued: false) {
                markFailed(id, notice ?? "可用空间不足")
                downloadTask.cancel()
            }
            persist()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let i = records.firstIndex(where: { $0.id == id }),
              (tasks[id] == nil || tasks[id]?.taskIdentifier == downloadTask.taskIdentifier),
              ["scheduled", "downloading", "pausing", "queued", "paused"].contains(records[i].status) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        guard let code = response?.statusCode, (200...299).contains(code),
              let source = URL(string: records[i].url), let finalURL = response?.url,
              DirectoryParser.sameOrigin(source, finalURL) else {
            markFailed(id, "下载失败：HTTP \(response?.statusCode ?? 0)，或服务器重定向到了其他地址"); return
        }
        // Preserve the synchronous move: URLSession removes its temp file when this callback returns.
        let name = (records[i].name as NSString).lastPathComponent
        let safeName = name.isEmpty || name == "." || name == ".." ? "下载文件" : name
        do {
            let destination = try FileDestination.move(location, to: documentURL, name: safeName)
            records[i].status = "completed"
            records[i].localName = destination.lastPathComponent
            if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path), let size = attrs[.size] as? NSNumber {
                records[i].bytes = size.int64Value
                records[i].size = size.int64Value
            }
            records[i].error = nil
            try? FileManager.default.removeItem(at: resumeURL(id))
            persist()
        } catch { markFailed(id, error.localizedDescription) }
    }
    private func markFailed(_ id: String, _ message: String) {
        guard let i = records.firstIndex(where: { $0.id == id }), !["completed", "cancelled", "cancelling"].contains(records[i].status) else { return }
        records[i].status = "failed"; records[i].error = message; persist()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        retiringTasks.remove(task.taskIdentifier)
        defer { startNextIfPossible() }
        guard let id = task.taskDescription, tasks[id]?.taskIdentifier == task.taskIdentifier else { return }
        tasks.removeValue(forKey: id)
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        if records[i].status == "cancelling" { records[i].status = "cancelled"; persist(); return }
        if let error = error as NSError? {
            if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               !["completed", "cancelled"].contains(records[i].status) {
                try? data.write(to: resumeURL(id), options: .atomic)
            }
            if ["pausing", "paused", "completed", "cancelled"].contains(records[i].status) { return }
            if error.code == NSURLErrorCancelled && records[i].status == "failed" { return }
            markFailed(id, error.localizedDescription + "。可重试；若续传失败，请选择从头下载。")
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Flush queued state writes before notifying iOS that background events are handled.
        storeQueue.async { DispatchQueue.main.async {
            let completion = self.backgroundCompletion
            self.backgroundCompletion = nil
            completion?()
        } }
    }
}

enum FileDestination {
    static func move(_ source: URL, to directory: URL, name: String) throws -> URL {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var number = 0
        while true {
            let candidate = number == 0 ? name : stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext)
            let destination = directory.appendingPathComponent(candidate)
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            } catch {
                // moveItem never overwrites; another writer may have won the name race.
                if FileManager.default.fileExists(atPath: destination.path) { number += 1; continue }
                throw error
            }
        }
    }
}

// Hold a Files-provider directory grant for the entire preview/share/file operation.
final class ScopedDirectoryAccess {
    let url: URL
    private let scoped: Bool
    init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}
final class LocalFileAccess {
    let directory: ScopedDirectoryAccess
    let url: URL
    init(folder: URL, name: String) throws {
        directory = ScopedDirectoryAccess(folder)
        let valid = try LocalFileOperations.validatedName(name)
        url = folder.appendingPathComponent(valid)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LANError(message: "文件不存在或不是可操作的普通文件，请在文件 App 中检查。")
        }
    }
}

enum LocalFileOperations {
    static func validatedName(_ name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              name.utf8.count <= 255 else { throw LANError(message: "文件名不能为空，不能包含路径分隔符或控制字符，长度不能超过 255 字节。") }
        return name
    }
    static func rename(_ source: URL, to name: String) throws -> URL {
        let destination = source.deletingLastPathComponent().appendingPathComponent(try validatedName(name))
        if source.standardizedFileURL == destination.standardizedFileURL { return source }
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: [], error: &coordinationError) { from, to in
            do {
                guard !FileManager.default.fileExists(atPath: to.path) else { throw LANError(message: "已存在同名文件，请换一个名称。") }
                try FileManager.default.moveItem(at: from, to: to)
            } catch { operationError = error }
        }
        if let error = coordinationError { throw error }
        if let error = operationError { throw error }
        return destination
    }
    static func delete(_ source: URL) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forDeleting, error: &coordinationError) { url in
            do { try FileManager.default.removeItem(at: url) } catch { operationError = error }
        }
        if let error = coordinationError { throw error }
        if let error = operationError { throw error }
    }
    static func transfer(_ source: URL, to folder: URL, moving: Bool) throws -> URL {
        guard (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw LANError(message: "请选择文件夹。") }
        if moving && source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL {
            throw LANError(message: "文件已经在这个文件夹中。")
        }
        var result: URL?
        var operationError: Error?
        var coordinationError: NSError?
        let transfer: (URL, URL) -> Void = { from, directory in
            do {
                let size = ((try FileManager.default.attributesOfItem(atPath: from.path))[.size] as? NSNumber)?.int64Value ?? 0
                if let available = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
                   size > available { throw LANError(message: "目标位置可用空间不足。") }
                let to = try copyWithoutOverwriting(from, to: directory)
                // A failed copy never removes the source. Providers handle cloud upload separately.
                let copied = ((try FileManager.default.attributesOfItem(atPath: to.path))[.size] as? NSNumber)?.int64Value
                guard copied == size else { throw LANError(message: "复制后的大小不一致，原文件保留；请检查目标位置的副本。") }
                if moving {
                    do { try FileManager.default.removeItem(at: from) }
                    catch { throw LANError(message: "副本已保存，但原文件未能移除；记录仍指向原文件。请检查目标文件夹。\n" + error.localizedDescription) }
                }
                result = to
            } catch { operationError = error }
        }
        let coordinator = NSFileCoordinator()
        if moving {
            coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: folder, options: [], error: &coordinationError, byAccessor: transfer)
        } else {
            coordinator.coordinate(readingItemAt: source, options: [], writingItemAt: folder, options: [], error: &coordinationError, byAccessor: transfer)
        }
        if let error = coordinationError { throw error }
        if let error = operationError { throw error }
        guard let result else { throw LANError(message: "文件操作未完成，原文件保留。") }
        return result
    }
    private static func copyWithoutOverwriting(_ source: URL, to folder: URL) throws -> URL {
        let name = source.lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for number in 0...10000 {
            let candidate = number == 0 ? name : stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext)
            let destination = folder.appendingPathComponent(try validatedName(candidate))
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            do { try FileManager.default.copyItem(at: source, to: destination); return destination }
            catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { continue }
                throw error
            }
        }
        throw LANError(message: "同名副本过多，请选择其他目标文件夹。")
    }
}

// Keep different origins in separate batches. Within a plain HTTP batch,
// URLSession's single connection handles progression without waking the app.
enum SerialDownloadQueue {
    static func origin(_ raw: String) -> String? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
    static func batchIDs(records: [DownloadRecord], restoring: Bool, outstanding: Bool) -> [String] {
        guard !restoring, !outstanding,
              !records.contains(where: { ["pausing", "cancelling"].contains($0.status) }) else { return [] }
        let active = records.first { ["scheduled", "downloading"].contains($0.status) }
        let first = active ?? records.first { $0.status == "queued" }
        guard let first, let selected = origin(first.url) else { return [] }
        return records.filter { $0.status == "queued" && origin($0.url) == selected }.map { $0.id }
    }
}
