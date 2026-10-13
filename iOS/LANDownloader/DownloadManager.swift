import Foundation
import Combine
import UIKit

final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    @Published private(set) var records: [DownloadRecord] = []
    private var session: URLSession!
    private var backgroundCompletion: (() -> Void)?
    private let storeQueue = DispatchQueue(label: "LANDownloader.store")
    private var activeTaskIDs = Set<String>()
    private var lastPersist = Date.distantPast

    private var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("downloads.json")
    }
    private var documentURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private override init() {
        super.init()
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            records = saved
        }
        let config = URLSessionConfiguration.background(withIdentifier: "com.lantransfer.downloader.background.v1")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = false
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
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
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch { NSLog("Save state failed: %@", error.localizedDescription) }
        }
    }

    private func restoreTasks() {
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                self.activeTaskIDs = Set(tasks.compactMap(\.taskDescription))
                for idx in self.records.indices where self.records[idx].status == "downloading" {
                    if !self.activeTaskIDs.contains(self.records[idx].id) {
                        self.records[idx].status = "interrupted"
                    }
                }
                self.persist()
            }
        }
    }

    func enqueue(_ files: [VideoFile]) {
        for file in files {
            guard let url = URL(string: file.url), url.scheme == "http" || url.scheme == "https" else { continue }
            if let existing = records.first(where: { $0.id == file.id }),
               existing.status == "downloading" || existing.status == "completed" { continue }
            records.removeAll { $0.id == file.id }
            records.append(DownloadRecord(id: file.id, path: file.path, name: file.name,
                                          url: file.url, size: file.size, bytes: 0,
                                          status: "downloading", localName: nil, error: nil))
            let task = session.downloadTask(with: url)
            task.taskDescription = file.id
            activeTaskIDs.insert(file.id)
            task.resume()
        }
        persist()
    }

    func retry(_ record: DownloadRecord) {
        let file = VideoFile(path: record.path, name: record.name, size: record.size, url: record.url)
        enqueue([file])
    }

    func cancel(_ record: DownloadRecord) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == record.id { task.cancel() }
        }
        if let i = records.firstIndex(where: { $0.id == record.id }) {
            records[i].status = "cancelled"
            records[i].error = nil
            persist()
        }
    }

    func remove(_ record: DownloadRecord) {
        guard record.status != "downloading" else { return }
        records.removeAll { $0.id == record.id }
        persist()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        DispatchQueue.main.async {
            guard let i = self.records.firstIndex(where: { $0.id == id }) else { return }
            self.records[i].bytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { self.records[i].size = totalBytesExpectedToWrite }
            if Date().timeIntervalSince(self.lastPersist) > 3 {
                self.lastPersist = Date()
                self.persist()
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // The system deletes this temporary file when this delegate callback returns.
        // Move it synchronously BEFORE dispatching UI state updates.
        let response = downloadTask.response as? HTTPURLResponse
        guard let code = response?.statusCode, (200...299).contains(code) else {
            let msg = "HTTP \(response?.statusCode ?? 0)"
            DispatchQueue.main.async { self.markFailed(id, msg) }
            return
        }
        let rawName = id.split(separator: "/").last.map(String.init) ?? "video"
        let safeName = (rawName as NSString).lastPathComponent
        let suffix = UUID().uuidString.prefix(8)
        let destination = documentURL.appendingPathComponent("\(suffix)_\(safeName)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            DispatchQueue.main.async {
                guard let i = self.records.firstIndex(where: { $0.id == id }) else { return }
                self.records[i].status = "completed"
                self.records[i].localName = destination.lastPathComponent
                if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
                   let fileSize = attrs[.size] as? NSNumber {
                    self.records[i].bytes = fileSize.int64Value
                }
                self.records[i].error = nil
                self.persist()
            }
        } catch {
            DispatchQueue.main.async { self.markFailed(id, error.localizedDescription) }
        }
    }

    private func markFailed(_ id: String, _ message: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[i].status != "completed" && records[i].status != "cancelled" else { return }
        records[i].status = "failed"
        records[i].error = message
        persist()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        DispatchQueue.main.async {
            self.activeTaskIDs.remove(id)
            if let error = error as NSError? {
                if error.code != NSURLErrorCancelled { self.markFailed(id, error.localizedDescription) }
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let completion = self.backgroundCompletion
            self.backgroundCompletion = nil
            completion?()
        }
    }
}
