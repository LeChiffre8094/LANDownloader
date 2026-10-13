import Foundation
import SwiftSoup

// Browse requests never execute HTML/JavaScript or fetch embedded resources.
final class BrowseRedirectGuard: NSObject, URLSessionTaskDelegate {
    let root: URL
    init(root: URL) { self.root = root }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { DirectoryParser.isWithinRoot($0, root: root) } == true ? request : nil)
    }
}

enum DirectoryParser {
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }
    static func isWithinRoot(_ url: URL, root: URL) -> Bool {
        guard sameOrigin(url, root), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        let base = root.pathComponents
        return Array(url.standardized.pathComponents.prefix(base.count)) == base
    }
    static func childURL(_ href: String, directory: URL, root: URL) -> URL? {
        let relative = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
        let rawPath = relative.split(separator: "?", maxSplits: 1).first.map(String.init) ?? relative
        for segment in rawPath.split(separator: "/") {
            let decoded = String(segment).removingPercentEncoding
            if decoded == "." || decoded == ".." { return nil }
        }
        guard !href.isEmpty, !href.hasPrefix("#"), !href.hasPrefix("?"),
              !href.contains("\\"), !href.unicodeScalars.contains(where: { $0.value < 32 }),
              let candidate = URL(string: relative, relativeTo: directory)?.absoluteURL,
              isWithinRoot(candidate, root: root) else { return nil }
        // Decode each path segment once. Encoded slashes, traversal and controls are rejected.
        guard let parts = URLComponents(url: candidate, resolvingAgainstBaseURL: true) else { return nil }
        for segment in parts.percentEncodedPath.split(separator: "/") {
            guard let decoded = String(segment).removingPercentEncoding,
                  decoded != ".", decoded != "..", !decoded.contains("/"), !decoded.contains("\\"),
                  !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        }
        let base = directory.pathComponents
        let path = candidate.pathComponents
        guard path.count == base.count + 1, Array(path.prefix(base.count)) == base else { return nil }
        return candidate
    }
    private struct Entry: Decodable {
        let name: String
        let size: Int64?
        let url: String
        let is_dir: Bool
        let mod_time: String?
    }
    static func parse(_ data: Data, mime: String?, directory: URL, root: URL) throws -> [VideoFile] {
        var result: [VideoFile] = []
        if let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            for entry in entries {
                guard let url = childURL(entry.url, directory: directory, root: root) else { continue }
                result.append(VideoFile(path: url.path, name: url.lastPathComponent,
                                        size: entry.size.map { max(0, $0) } ?? -1, url: url.absoluteString,
                                        isDirectory: entry.is_dir, modified: entry.mod_time))
            }
        } else {
            guard mime == "text/html", let html = String(data: data, encoding: .utf8) else {
                throw LANError(message: "无法识别目录。请启用 Caddy --browse。")
            }
            let document = try SwiftSoup.parse(html)
            // Only Caddy listing rows, never navigation, script content or arbitrary page links.
            let rows = try document.select("table tbody tr")
            guard !(try document.select("table")).isEmpty() else {
                throw LANError(message: "此地址不是 Caddy 文件目录，可能存在 index.html 首页。")
            }
            for row in rows.array() {
                guard let anchor = try row.select("a[href]").first(),
                      let url = childURL(try anchor.attr("href"), directory: directory, root: root) else { continue }
                let isDirectory = url.absoluteString.hasSuffix("/")
                // Caddy HTML templates vary; unknown size is safer than parsing rounded display text.
                result.append(VideoFile(path: url.path, name: url.lastPathComponent, size: -1,
                                        url: url.absoluteString, isDirectory: isDirectory))
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

final class DirectoryBrowser {
    func load(directory: URL, root: URL) async throws -> [VideoFile] {
        guard DirectoryParser.isWithinRoot(directory, root: root) else { throw LANError(message: "目录超出服务器共享范围") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.allowsCellularAccess = false
        let session = URLSession(configuration: config, delegate: BrowseRedirectGuard(root: root), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: directory, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json, text/html;q=0.8", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = response.url, DirectoryParser.isWithinRoot(finalURL, root: root) else {
            throw LANError(message: "目录请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。请检查地址、端口和 Caddy。")
        }
        let limit = 8 * 1024 * 1024
        guard response.expectedContentLength <= Int64(limit) else { throw LANError(message: "目录清单过大，请分到子文件夹后重试") }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { throw LANError(message: "目录清单超过 8 MB，请分到子文件夹") }
            data.append(byte)
        }
        return try DirectoryParser.parse(data, mime: response.mimeType, directory: finalURL, root: root)
    }
}
