import SwiftUI

struct ContentView: View {
    @StateObject private var manager = DownloadManager.shared
    @AppStorage("serverURL") private var serverURL = "http://192.168.0.245:8080"
    @State private var files: [VideoFile] = []
    @State private var selected = Set<String>()
    @State private var error: String?
    @State private var isLoading = false
    @State private var search = ""

    private var filtered: [VideoFile] {
        search.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(search) }
    }
    private var selectedFiles: [VideoFile] { files.filter { selected.contains($0.id) } }
    private var selectedBytes: Int64 { selectedFiles.reduce(Int64(0)) { $0 &+ $1.size } }

    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section("Windows 文件服务器") {
                        TextField("服务器地址", text: $serverURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button(isLoading ? "正在刷新…" : "刷新文件清单") { Task { await loadFiles() } }
                            .disabled(isLoading)
                        if let error { Text(error).foregroundColor(.red).font(.footnote) }
                    }
                    Section {
                        HStack {
                            Button(selected.count == filtered.count && !filtered.isEmpty ? "取消全选" : "全选") {
                                let ids = Set(filtered.map(\.id))
                                if selected.isSuperset(of: ids) { selected.subtract(ids) }
                                else { selected.formUnion(ids) }
                            }
                            Spacer()
                            Text("已选 \(selected.count) 项 · \(sizeString(selectedBytes))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(filtered) { file in
                            Button {
                                if !selected.insert(file.id).inserted { selected.remove(file.id) }
                            } label: {
                                HStack {
                                    Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(file.id) ? .blue : .gray)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.name).foregroundStyle(.primary).lineLimit(2)
                                        Text(file.path + " · " + sizeString(file.size))
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    } header: { Text("视频文件（\(filtered.count)）") }
                }
                .searchable(text: $search, prompt: "搜索文件名或目录")
                .navigationTitle("局域网视频")
                .safeAreaInset(edge: .bottom) {
                    Button("加入后台下载队列（\(selected.count)）") {
                        manager.enqueue(selectedFiles)
                        selected.removeAll()
                    }
                    .disabled(selected.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.regularMaterial)
                }
                .task { await loadFiles() }
            }
            .tabItem { Label("文件", systemImage: "folder") }

            NavigationStack {
                List {
                    ForEach(manager.records) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.name).font(.subheadline).lineLimit(2)
                            HStack {
                                Text(statusLabel(record.status))
                                Spacer()
                                Text("\(sizeString(record.bytes)) / \(sizeString(record.size))")
                            }.font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: record.progress)
                            if let error = record.error { Text(error).font(.caption2).foregroundStyle(.red) }
                            HStack {
                                if ["failed", "interrupted", "cancelled"].contains(record.status) {
                                    Button("重新下载") { manager.retry(record) }.buttonStyle(.bordered)
                                }
                                if record.status == "downloading" {
                                    Button("取消") { manager.cancel(record) }.buttonStyle(.bordered)
                                }
                                if record.status != "downloading" {
                                    Button("移除记录") { manager.remove(record) }.buttonStyle(.bordered)
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                }
                .navigationTitle("下载任务")
                .overlay {
                    if manager.records.isEmpty {
                        Text("暂无下载任务").foregroundStyle(.secondary)
                    }
                }
            }
            .tabItem { Label("下载", systemImage: "arrow.down.circle") }
        }
    }

    @MainActor
    private func loadFiles() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let base = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = base.scheme, ["http", "https"].contains(scheme.lowercased()),
                  let url = URL(string: "_lan_manifest.json", relativeTo: base.appendingPathComponent("/"))?.absoluteURL else {
                throw NSError(domain: "LAN", code: 1, userInfo: [NSLocalizedDescriptionKey: "服务器地址无效"])
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "LAN", code: 2, userInfo: [NSLocalizedDescriptionKey: "清单不可访问，请先运行 Windows 生成脚本"])
            }
            let manifest = try JSONDecoder().decode(VideoManifest.self, from: data)
            guard manifest.version == 1 else { throw NSError(domain: "LAN", code: 3, userInfo: [NSLocalizedDescriptionKey: "文件清单版本不受支持"]) }
            files = manifest.files.filter { item in
                guard let url = URL(string: item.url), let host = base.host else { return false }
                return url.host == host && url.port == base.port && url.scheme == base.scheme && item.size >= 0
            }
            selected.formIntersection(Set(files.map(\.id)))
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func sizeString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func statusLabel(_ status: String) -> String {
        switch status {
        case "downloading": return "下载中"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "interrupted": return "已中断"
        case "cancelled": return "已取消"
        default: return status
        }
    }
}
