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
    private var session: URLSession!
    private var backgroundCompletion: (() -> Void)?
    private let storeQueue = DispatchQueue(label: "LANDownloader.store")
    private var tasks: [String: URLSessionDownloadTask] = [:]
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
    private func restoreTasks() {
        session.getAllTasks { existing in
            DispatchQueue.main.async {
                for task in existing {
                    guard let download = task as? URLSessionDownloadTask, let id = task.taskDescription,
                          let i = self.records.firstIndex(where: { $0.id == id }) else { task.cancel(); continue }
                    if ["completed", "cancelled", "cancelling", "failed"].contains(self.records[i].status) {
                        if self.records[i].status == "cancelling" { self.records[i].status = "cancelled" }
                        task.cancel(); continue
                    }
                    self.tasks[id] = download
                    if self.records[i].status == "paused" {
                        task.suspend()
                    } else {
                        self.records[i].status = "downloading"
                        task.resume()
                    }
                }
                for i in self.records.indices where ["downloading", "pausing", "cancelling"].contains(self.records[i].status) && self.tasks[self.records[i].id] == nil {
                    let id = self.records[i].id
                    if self.records[i].status == "cancelling" { self.records[i].status = "cancelled"; continue }
                    self.records[i].status = FileManager.default.fileExists(atPath: self.resumeURL(id).path) ? "paused" : "interrupted"
                }
                self.restoring = false
                self.persist()
            }
        }
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
    private func checkCapacity(additional: Int64, excluding id: String? = nil) -> Bool {
        guard let available = availableBytes() else {
            notice = "无法读取设备可用空间，请稍后重试。"; return false
        }
        let remaining = records.filter { $0.status == "downloading" && $0.id != id }.reduce(reserve) {
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
                  let url = URL(string: file.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  !records.contains(where: { $0.url == file.url && ["downloading", "pausing", "paused", "cancelling", "completed"].contains($0.status) }) else { continue }
            accepted.append(file)
        }
        let bytes = accepted.reduce(Int64(0)) { saturatedAdd($0, $1.size) }
        guard !accepted.isEmpty else { notice = "所选文件已有下载任务或已完成，可在下载页查看。"; return 0 }
        guard checkCapacity(additional: bytes) else { return 0 }
        for file in accepted {
            let record = DownloadRecord(id: UUID().uuidString, path: file.path, name: file.name,
                                        url: file.url, size: file.size, bytes: 0, status: "downloading", localName: nil, error: nil)
            records.append(record)
            start(record, resume: false)
        }
        persist()
        return accepted.count
    }
    private func start(_ record: DownloadRecord, resume: Bool) {
        guard let url = URL(string: record.url), let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        let task: URLSessionDownloadTask
        if resume, let data = try? Data(contentsOf: resumeURL(record.id)) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: url)
            records[i].bytes = 0
        }
        records[i].status = "downloading"
        records[i].error = nil
        task.taskDescription = record.id
        tasks[record.id] = task
        persist()
        // Persist record before the OS starts work, so relaunch can reconcile it.
        storeQueue.async { DispatchQueue.main.async {
            if self.tasks[record.id]?.taskIdentifier == task.taskIdentifier && self.records.first(where: { $0.id == record.id })?.status == "downloading" { task.resume() }
        } }
    }
    func retry(_ record: DownloadRecord, fromBeginning: Bool = false) {
        guard !restoring, let i = records.firstIndex(where: { $0.id == record.id }),
              ["paused", "failed", "interrupted", "cancelled"].contains(records[i].status) else { return }
        let current = records[i]
        let canResume = !fromBeginning && (tasks[record.id] != nil || FileManager.default.fileExists(atPath: resumeURL(record.id).path))
        guard checkCapacity(additional: max(0, current.size - (canResume ? current.bytes : 0)), excluding: record.id) else { return }
        if let task = tasks[record.id], current.status == "paused", !fromBeginning {
            records[i].status = "downloading"; task.resume(); persist(); return
        }
        if fromBeginning, let oldTask = tasks.removeValue(forKey: record.id) { oldTask.cancel() }
        guard tasks[record.id] == nil else { return }
        if fromBeginning { try? FileManager.default.removeItem(at: resumeURL(record.id)) }
        start(current, resume: !fromBeginning)
    }
    func pause(_ record: DownloadRecord) {
        guard let task = tasks[record.id], let i = records.firstIndex(where: { $0.id == record.id }), records[i].status == "downloading" else { return }
        records[i].status = "pausing"
        try? FileManager.default.removeItem(at: resumeURL(record.id))
        persist()
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
            }
        })
    }
    func cancel(_ record: DownloadRecord) {
        guard let i = records.firstIndex(where: { $0.id == record.id }), !["pausing", "completed"].contains(records[i].status) else { return }
        records[i].status = tasks[record.id] == nil ? "cancelled" : "cancelling"
        records[i].error = nil
        tasks[record.id]?.cancel()
        try? FileManager.default.removeItem(at: resumeURL(record.id))
        persist()
    }
    func remove(_ record: DownloadRecord) {
        guard !["downloading", "pausing", "cancelling"].contains(record.status) else { return }
        tasks.removeValue(forKey: record.id)?.cancel()
        records.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: resumeURL(record.id))
        persist()
    }
    func localURL(_ record: DownloadRecord) -> URL? {
        guard let name = record.localName, name == (name as NSString).lastPathComponent else { return nil }
        let url = documentURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, let i = records.firstIndex(where: { $0.id == id }),
              (tasks[id] == nil || tasks[id]?.taskIdentifier == downloadTask.taskIdentifier), records[i].status == "downloading" else { return }
        tasks[id] = downloadTask
        records[i].bytes = totalBytesWritten
        if totalBytesExpectedToWrite > 0 { records[i].size = totalBytesExpectedToWrite }
        if Date().timeIntervalSince(lastPersist) > 3 {
            lastPersist = Date()
            if !checkCapacity(additional: max(0, records[i].size - totalBytesWritten), excluding: id) {
                markFailed(id, notice ?? "可用空间不足")
                downloadTask.cancel()
            }
            persist()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let i = records.firstIndex(where: { $0.id == id }),
              (tasks[id] == nil || tasks[id]?.taskIdentifier == downloadTask.taskIdentifier),
              ["downloading", "pausing"].contains(records[i].status) else { return }
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
        guard let id = task.taskDescription, tasks[id]?.taskIdentifier == task.taskIdentifier else { return }
        tasks.removeValue(forKey: id)
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        if records[i].status == "cancelling" { records[i].status = "cancelled"; persist(); return }
        if let error = error as NSError?, !["pausing", "paused", "completed", "cancelled"].contains(records[i].status) {
            if error.code == NSURLErrorCancelled && records[i].status == "failed" { return }
            if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? data.write(to: resumeURL(id), options: .atomic) }
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
