import Foundation
import SwiftUI

// Kept for compatibility with the v0.1 download manager; now represents any file.
struct VideoFile: Decodable, Identifiable {
    let path: String
    let name: String
    let size: Int64
    let url: String
    var isDirectory: Bool = false
    var modified: String? = nil
    var id: String { url }
    var category: FileCategory { FileCategory.classify(name) }
}

enum FileCategory: String, CaseIterable, Identifiable {
    case all = "全部", video = "视频", image = "图片", audio = "音频", document = "文档", archive = "压缩包", other = "其他"
    var id: String { rawValue }
    var extensions: Set<String> {
        switch self {
        case .video: return Set("mp4 mkv mov m4v avi ts m2ts mts webm flv wmv mpg mpeg 3gp 3g2 vob ogv rm rmvb asf".split(separator: " ").map(String.init))
        case .image: return Set("jpg jpeg png heic heif gif bmp webp tif tiff svg avif raw dng".split(separator: " ").map(String.init))
        case .audio: return Set("mp3 flac m4a wav aac ogg opus aiff alac wma ape".split(separator: " ").map(String.init))
        case .document: return Set("pdf doc docx xls xlsx ppt pptx txt rtf md csv epub pages numbers key json xml log srt ass vtt".split(separator: " ").map(String.init))
        case .archive: return Set("zip rar 7z tar gz bz2 xz tgz zst iso".split(separator: " ").map(String.init))
        default: return []
        }
    }
    static func classify(_ name: String) -> FileCategory {
        let ext = (name as NSString).pathExtension.lowercased()
        return allCases.first { $0 != .all && $0.extensions.contains(ext) } ?? .other
    }
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2.fill"
        case .video: return "video.fill"
        case .image: return "photo.fill"
        case .audio: return "music.note"
        case .document: return "doc.text.fill"
        case .archive: return "archivebox.fill"
        case .other: return "ellipsis"
        }
    }
    var color: Color {
        switch self {
        case .video: return .purple
        case .image: return .green
        case .audio: return .orange
        case .archive: return .yellow
        case .other: return .gray
        default: return .blue
        }
    }
    var detail: String {
        switch self {
        case .all: return "显示所有类型的文件"
        case .other: return "未归类的文件类型"
        default: return extensions.sorted().map { $0.uppercased() }.joined(separator: "、")
        }
    }
}

struct DownloadRecord: Codable, Identifiable {
    var id: String
    var path: String
    var name: String
    var url: String
    var size: Int64
    var bytes: Int64
    var status: String
    var localName: String?
    var error: String?
    var progress: Double { size > 0 ? min(1, Double(bytes) / Double(size)) : 0 }
}

func sizeString(_ bytes: Int64) -> String {
    bytes < 0 ? "大小未知" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct LANError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Server: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var address: String
    var rootURL: URL? { URL(string: address) }
    static func normalizedAddress(_ value: String) throws -> String {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw LANError(message: "请输入服务器地址") }
        let prefixed = input.contains("://") ? input : "http://" + input
        guard var parts = URLComponents(string: prefixed),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!) else {
            throw LANError(message: "地址格式无效，例如 http://192.168.0.245:8080")
        }
        parts.scheme = parts.scheme?.lowercased()
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { throw LANError(message: "服务器地址无效") }
        return url.absoluteString
    }
}

final class ServerStore: ObservableObject {
    @Published var servers: [Server] = []
    @Published var selectedID: UUID?
    var selected: Server? { servers.first { $0.id == selectedID } }
    init() {
        if let data = UserDefaults.standard.data(forKey: "servers.v2"),
           let saved = try? JSONDecoder().decode([Server].self, from: data) {
            servers = saved
            selectedID = UserDefaults.standard.string(forKey: "selectedServer.v2").flatMap(UUID.init(uuidString:))
        } else if let old = UserDefaults.standard.string(forKey: "serverURL"),
                  let address = try? Server.normalizedAddress(old) {
            servers = [Server(name: "台式机", address: address)]
        }
        if selected == nil { selectedID = servers.first?.id }
        persist()
    }
    func save(_ server: Server) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) { servers[i] = server }
        else { servers.append(server) }
        if selectedID == nil { selectedID = server.id }
        persist()
    }
    func select(_ server: Server) { selectedID = server.id; persist() }
    func delete(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        if selectedID == server.id { selectedID = servers.first?.id }
        persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: "servers.v2") }
        UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedServer.v2")
    }
}
