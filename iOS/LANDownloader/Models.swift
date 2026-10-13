import Foundation

struct VideoManifest: Decodable {
    let version: Int
    let generatedAt: String
    let files: [VideoFile]
}

struct VideoFile: Decodable, Identifiable {
    let path: String
    let name: String
    let size: Int64
    let url: String
    var id: String { path }
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
