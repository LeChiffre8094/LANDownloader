import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var manager = DownloadManager.shared
    @StateObject private var servers = ServerStore()
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            FilesView(servers: servers, manager: manager, showServers: { tab = 2 })
                .tabItem { Label("文件", systemImage: "folder.fill") }.tag(0)
            DownloadsView(manager: manager)
                .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }.tag(1)
            ServersView(store: servers)
                .tabItem { Label("服务器", systemImage: "server.rack") }.tag(2)
        }
        .tint(.blue)
        .alert("提示", isPresented: Binding(get: { manager.notice != nil }, set: { if !$0 { manager.notice = nil } })) {
            Button("知道了") { manager.notice = nil }
        } message: { Text(manager.notice ?? "") }
    }
}

struct FilesView: View {
    @ObservedObject var servers: ServerStore
    @ObservedObject var manager: DownloadManager
    let showServers: () -> Void
    @State private var files: [VideoFile] = []
    @State private var selected = Set<String>()
    @State private var path: [String] = []
    @State private var search = ""
    @State private var category = FileCategory.all
    @State private var includeSubfolders = true
    @State private var showFilter = false
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()
    private var directory: URL? {
        guard var url = servers.selected?.rootURL else { return nil }
        for component in path { url.appendPathComponent(component, isDirectory: true) }
        return url
    }
    private var recursiveSearch: Bool { category != .all && includeSubfolders }
    private var filtered: [VideoFile] {
        files.filter { (category == .all || (!$0.isDirectory && $0.category == category)) && (search.isEmpty || ($0.name.localizedCaseInsensitiveContains(search) || (recursiveSearch && $0.path.localizedCaseInsensitiveContains(search)))) }
    }
    private var selectable: [VideoFile] { filtered.filter { !$0.isDirectory } }
    private var selectedFiles: [VideoFile] { files.filter { selected.contains($0.id) && !$0.isDirectory } }
    private var selectedSummary: String {
        let known = selectedFiles.reduce(Int64(0)) { value, file in
            let result = value.addingReportingOverflow(max(0, file.size))
            return result.overflow ? Int64.max : result.partialValue
        }
        return "已选择 \(selectedFiles.count) 项 · \(sizeString(known))" + (selectedFiles.contains { $0.size < 0 } ? "＋未知大小" : "")
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Menu {
                        ForEach(servers.servers) { server in Button(server.name) { path = []; servers.select(server) } }
                        Button("管理服务器", action: showServers)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer").font(.title2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(servers.selected?.name ?? "添加文件服务器").font(.subheadline.bold())
                                Text(servers.selected?.address ?? "连接同一 Wi-Fi 下的电脑").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.down").font(.caption)
                        }.foregroundStyle(.primary).padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(recursiveSearch ? "搜索文件名或子目录" : "搜索当前目录文件名", text: $search).font(.subheadline).autocorrectionDisabled()
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") } }
                    }.padding(10).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(FileCategory.allCases) { item in
                                    Button { category = item } label: {
                                        Label(item.rawValue, systemImage: item.symbol).font(.caption).padding(.horizontal, 10).padding(.vertical, 9)
                                            .background(category == item ? Color.blue : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9))
                                            .foregroundStyle(category == item ? Color.white : Color.primary)
                                    }
                                }
                            }
                        }
                        Button { showFilter = true } label: { Image(systemName: "line.3.horizontal.decrease.circle").font(.title3) }.accessibilityLabel("文件类型筛选")
                    }
                    if category != .all {
                        Toggle("同时筛选子文件夹", isOn: $includeSubfolders).font(.caption)
                    }
                    HStack {
                        if !path.isEmpty { Button { path.removeLast() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上一级") }
                        Button { path = [] } label: { Image(systemName: "house") }.accessibilityLabel("共享根目录")
                        Text(path.isEmpty ? "共享目录" : path.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button(selected.isSuperset(of: Set(selectable.map(\.id))) && !selectable.isEmpty ? "取消全选" : "全选") {
                            let ids = Set(selectable.map(\.id))
                            if selected.isSuperset(of: ids) { selected.subtract(ids) } else { selected.formUnion(ids) }
                        }.font(.caption).disabled(selectable.isEmpty)
                    }
                }.padding(.horizontal).padding(.bottom, 10)
                if files.count >= 10000 {
                    Text("目录项目很多，Caddy 可能限制了返回数量，建议分到子目录浏览。").font(.caption).foregroundStyle(.orange).padding(.horizontal)
                }
                if let error {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                        Text(error).font(.subheadline).multilineTextAlignment(.center)
                        Button("重试") { Task { await load() } }.buttonStyle(.borderedProminent)
                    }.padding()
                }
                List {
                    ForEach(filtered) { file in
                        Button {
                            if file.isDirectory { path.append(file.name) }
                            else if !selected.insert(file.id).inserted { selected.remove(file.id) }
                        } label: {
                            HStack(spacing: 12) {
                                if !file.isDirectory {
                                    Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(file.id) ? Color.blue : Color.gray).font(.title3)
                                }
                                FileBadge(name: file.name, directory: file.isDirectory)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(file.name).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                                    if recursiveSearch, let directory {
                                        Text(relativeFolder(file, from: directory)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    HStack {
                                        Text(file.isDirectory ? "文件夹" : file.category.rawValue)
                                        Spacer()
                                        if !file.isDirectory { Text(sizeString(file.size)) }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                if file.isDirectory { Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption) }
                            }.padding(.vertical, 5)
                        }.listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                    }
                }
                .listStyle(.plain)
                .refreshable { if !loading { await load() } }
                .overlay {
                    if loading { ProgressView(recursiveSearch ? "正在汇总子文件夹…" : "正在读取目录…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                    else if filtered.isEmpty && error == nil {
                        VStack(spacing: 12) {
                            Image(systemName: servers.selected == nil ? "network" : "folder").font(.largeTitle)
                            Text(servers.selected == nil ? "先添加电脑的文件服务器" : "当前目录没有匹配的文件").font(.subheadline)
                            if servers.selected == nil { Button("添加服务器", action: showServers).buttonStyle(.borderedProminent) }
                        }.foregroundStyle(.secondary)
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("局域网文件传输").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button(action: showServers) { Image(systemName: "gearshape") }.accessibilityLabel("服务器设置") }
                ToolbarItem(placement: .navigationBarLeading) { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading || directory == nil).accessibilityLabel("刷新") }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text(selectedSummary).font(.caption).foregroundStyle(.blue)
                    Spacer()
                    Button("加入下载队列") { if manager.enqueue(selectedFiles) > 0 { selected.removeAll() } }
                        .buttonStyle(.borderedProminent).disabled(selectedFiles.isEmpty || manager.restoring)
                }.padding().background(.regularMaterial)
            }
            .sheet(isPresented: $showFilter) { FilterView(selection: $category) }
            .onChange(of: servers.selected?.address) { _ in path = []; selected = []; files = [] }
            .onChange(of: category) { _ in selected.formIntersection(Set(selectable.map(\.id))) }
            .onChange(of: search) { _ in selected.formIntersection(Set(selectable.map(\.id))) }
            .task(id: (directory?.absoluteString ?? "") + (recursiveSearch ? "|recursive" : "|single")) { await load() }
        }
    }
    private func relativeFolder(_ file: VideoFile, from directory: URL) -> String {
        guard let url = URL(string: file.url) else { return "" }
        let parts = url.deletingLastPathComponent().pathComponents.dropFirst(directory.pathComponents.count)
        return parts.isEmpty ? "当前目录" : parts.joined(separator: " / ")
    }
    @MainActor private func load() async {
        let token = UUID(); requestID = token
        files = []; selected = []; error = nil
        guard let directory, let root = servers.selected?.rootURL else { loading = false; return }
        loading = true
        do {
            let browser = DirectoryBrowser()
            let result: [VideoFile]
            if recursiveSearch { result = try await browser.loadRecursively(directory: directory, root: root) }
            else { result = try await browser.load(directory: directory, root: root) }
            guard requestID == token, !Task.isCancelled else { return }
            files = result
        } catch {
            guard requestID == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        if requestID == token { loading = false }
    }
}

struct FilterView: View {
    @Binding var selection: FileCategory
    @Environment(\.dismiss) private var dismiss
    @State private var draft = FileCategory.all
    var body: some View {
        NavigationStack {
            List(FileCategory.allCases) { category in
                Button { draft = category } label: {
                    HStack(spacing: 14) {
                        Image(systemName: category.symbol).font(.title2).foregroundStyle(.white).frame(width: 44, height: 44).background(category.color.gradient, in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(category == .all ? "全部文件" : category.rawValue + "文件").foregroundStyle(.primary)
                            Text(category.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer()
                        Image(systemName: draft == category ? "checkmark.circle.fill" : "circle").foregroundStyle(draft == category ? Color.blue : Color.gray)
                    }.padding(.vertical, 6)
                }
            }.listStyle(.plain)
            .navigationTitle("文件类型筛选").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("取消") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button { selection = draft; dismiss() } label: { Text("确认").frame(maxWidth: .infinity).padding(8) }.buttonStyle(.borderedProminent).padding()
            }
        }.onAppear { draft = selection }
    }
}

struct FileBadge: View {
    let name: String
    var directory = false
    var body: some View {
        let category = FileCategory.classify(name)
        Image(systemName: directory ? "folder.fill" : category.symbol)
            .font(.title2).foregroundStyle(.white)
            .frame(width: 48, height: 52)
            .background((directory ? Color.blue : category.color).gradient, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

enum CompletedFileAction: String, CaseIterable, Identifiable {
    case share = "分享", rename = "重命名", move = "移动", copy = "复制", deleteFile = "删除文件", deleteRecord = "删除记录"
    var id: String { rawValue }
    var destructive: Bool { self == .deleteFile || self == .deleteRecord }
    var symbol: String {
        switch self {
        case .share: return "square.and.arrow.up"
        case .rename: return "pencil"
        case .move: return "folder"
        case .copy: return "doc.on.doc"
        case .deleteFile: return "trash"
        case .deleteRecord: return "list.bullet.rectangle"
        }
    }
}
private struct FilePanel: Identifiable {
    enum Kind { case menu, preview, share, move, copy }
    let id = UUID()
    let kind: Kind
    let record: DownloadRecord
    var access: LocalFileAccess? = nil
}
private struct PendingFileAction {
    let record: DownloadRecord
    let action: CompletedFileAction
}

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @State private var video: FloatingVideoSession?
    @State private var completed = false
    @State private var panel: FilePanel?
    @State private var pendingAction: PendingFileAction?
    @State private var renaming: DownloadRecord?
    @State private var newName = ""
    @State private var deletion: PendingFileAction?
    private var shown: [DownloadRecord] {
        if completed { return Array(manager.records.filter { $0.status == "completed" }.reversed()) }
        let active = manager.records.filter { ["downloading", "pausing", "cancelling"].contains($0.status) }
        let queued = manager.records.filter { ["queued", "scheduled"].contains($0.status) }
        let other = manager.records.filter { !["completed", "downloading", "pausing", "cancelling", "queued", "scheduled"].contains($0.status) }
        return active + queued + other
    }
    var body: some View {
        NavigationStack {
            VStack {
                Picker("任务状态", selection: $completed) {
                    Text("下载任务 (\(manager.records.filter { $0.status != "completed" }.count))").tag(false)
                    Text("已完成 (\(manager.records.filter { $0.status == "completed" }.count))").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal)
                List(shown) { record in
                    if record.status == "completed" { completedRow(record) }
                    else { taskRow(record) }
                }.listStyle(.insetGrouped)
                .overlay { if shown.isEmpty { Text(completed ? "暂无已完成文件" : "暂无下载任务").foregroundStyle(.secondary) } }
            }.background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("局域网文件传输").navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .top) {
                if let video {
                    FloatingVideoPlayer(session: video) { self.video = nil }
                }
            }
            .onDisappear { video?.close(); video = nil }
            .sheet(item: $panel, onDismiss: performPendingAction) { item in
                switch item.kind {
                case .menu:
                    CompletedFileMenu(name: item.record.localName ?? item.record.name) { action in
                        pendingAction = PendingFileAction(record: item.record, action: action)
                        panel = nil
                    } onCancel: { panel = nil }
                    .presentationDetents([.height(540), .large])
                    .presentationDragIndicator(.visible)
                case .preview:
                    if let access = item.access { FilePreviewSheet(url: access.url) { panel = nil } }
                case .share:
                    if let access = item.access { FileShareView(access: access) }
                case .move, .copy:
                    DestinationFolderPicker { folder in
                        if let folder { manager.transferFile(item.record, to: folder, moving: item.kind == .move) }
                        panel = nil
                    }
                }
            }
            .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("文件名（含扩展名）", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") { if let record = renaming { manager.renameFile(record, to: newName) }; renaming = nil }
            } message: { Text("请保留正确的扩展名；重名时不会覆盖已有文件。") }
            .alert(deletion?.action == .deleteFile ? "删除文件？" : "删除记录？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                Button("取消", role: .cancel) { deletion = nil }
                Button("删除", role: .destructive) {
                    if let request = deletion {
                        if request.action == .deleteFile { manager.deleteFile(request.record) }
                        else { manager.remove(request.record) }
                    }
                    deletion = nil
                }
            } message: {
                Text(deletion?.action == .deleteFile ? "将删除实际文件及这条下载记录。此操作无法在 App 内撤销。" : "仅删除这条下载记录，实际文件保留，可在文件 App 中找到。")
            }
        }
    }
    private func completedRow(_ record: DownloadRecord) -> some View {
        HStack(spacing: 8) {
            Button { open(record, kind: .preview) } label: {
                HStack(spacing: 12) {
                    FileBadge(name: record.name)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.localName ?? record.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        Text(sizeString(record.size)).font(.caption).foregroundStyle(.secondary)
                        if let error = record.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("预览文件")
            Button { video?.close(); video = nil; panel = FilePanel(kind: .menu, record: record) } label: {
                Image(systemName: "ellipsis").font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.blue).frame(width: 48, height: 48)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
            }.buttonStyle(.borderless).accessibilityLabel("更多操作：\(record.name)")
            if manager.fileOperationID == record.id { ProgressView().accessibilityLabel("正在处理文件") }
        }.padding(.vertical, 8).disabled(manager.fileOperationID != nil)
    }
    private func taskRow(_ record: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                FileBadge(name: record.name)
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.name).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text("\(sizeString(record.bytes)) / \(sizeString(record.size))").font(.caption).foregroundStyle(.secondary)
                    if record.size > 0 { ProgressView(value: record.progress).tint(.blue) }
                    else if record.status == "downloading" { ProgressView() }
                    Text(status(record.status)).font(.caption).foregroundStyle(.secondary)
                }
                if ["downloading", "queued", "scheduled"].contains(record.status) {
                    Button { manager.pause(record) } label: { Image(systemName: "pause.circle.fill").font(.title2) }.buttonStyle(.borderless).accessibilityLabel("暂停下载")
                } else if record.status == "paused" {
                    Button { manager.retry(record) } label: { Image(systemName: "play.circle.fill").font(.title2) }.buttonStyle(.borderless).accessibilityLabel("继续下载")
                }
            }
            if let error = record.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if ["failed", "interrupted", "cancelled"].contains(record.status) { Button("重试") { manager.retry(record) }.buttonStyle(.bordered) }
                Spacer()
                Menu {
                    if ["downloading", "queued", "scheduled", "paused"].contains(record.status) { Button("取消下载", role: .destructive) { manager.cancel(record) } }
                    if ["paused", "failed", "interrupted", "cancelled"].contains(record.status) { Button("从头下载") { manager.retry(record, fromBeginning: true) } }
                    if !["downloading", "pausing", "cancelling"].contains(record.status) { Button("删除记录", role: .destructive) { manager.remove(record) } }
                } label: { Image(systemName: "ellipsis").font(.title3).frame(width: 48, height: 48) }
                .disabled(["pausing", "cancelling"].contains(record.status))
            }.font(.caption)
        }.padding(.vertical, 8)
    }
    private func open(_ record: DownloadRecord, kind: FilePanel.Kind) {
        do {
            let access = try manager.accessibleFile(record)
            if kind == .preview && FileCategory.classify(access.url.lastPathComponent) == .video {
                video?.close()
                video = FloatingVideoSession(access: access)
            } else {
                video?.close(); video = nil
                panel = FilePanel(kind: kind, record: record, access: access)
            }
        }
        catch { manager.notice = error.localizedDescription }
    }
    private func performPendingAction() {
        guard let request = pendingAction else { return }
        pendingAction = nil
        switch request.action {
        case .share: open(request.record, kind: .share)
        case .move: open(request.record, kind: .move)
        case .copy: open(request.record, kind: .copy)
        case .rename:
            newName = request.record.localName ?? request.record.name
            renaming = request.record
        case .deleteFile, .deleteRecord: deletion = request
        }
    }
    private func status(_ status: String) -> String {
        ["queued": "等待服务器批次", "scheduled": "系统排队中 · 已提交后台", "downloading": "下载中", "failed": "下载失败", "interrupted": "已中断", "paused": "已暂停", "pausing": "正在暂停…", "cancelling": "正在取消…", "cancelled": "已取消"][status] ?? status
    }
}

struct CompletedFileMenu: View {
    let name: String
    let onAction: (CompletedFileAction) -> Void
    let onCancel: () -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(name).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).padding(.top, 20)
                VStack(spacing: 0) {
                    ForEach(CompletedFileAction.allCases) { action in
                        Button { onAction(action) } label: {
                            HStack {
                                Text(action.rawValue)
                                Spacer()
                                Image(systemName: action.symbol)
                            }.font(.body).foregroundStyle(action.destructive ? Color.red : Color.primary)
                                .padding(.horizontal, 20).frame(minHeight: 52).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if action != .deleteRecord { Divider().padding(.leading, 20) }
                    }
                }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                Button(action: onCancel) {
                    Text("取消").font(.body.weight(.semibold)).foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }.padding(.horizontal, 16).padding(.bottom, 16)
        }.background(Color(uiColor: .systemGroupedBackground))
    }
}

struct FileShareView: UIViewControllerRepresentable {
    let access: LocalFileAccess
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [access.url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct DestinationFolderPicker: UIViewControllerRepresentable {
    let onFinish: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        controller.allowsMultipleSelection = false
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (URL?) -> Void
        init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish(nil) }
    }
}

// Keep the close control outside Quick Look so video controls cannot hide it.
struct FilePreviewSheet: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Label("返回", systemImage: "chevron.left")
                        .font(.body.weight(.medium))
                        .frame(minWidth: 60, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .accessibilityLabel("返回文件列表")
                Text(url.lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color(uiColor: .systemBackground))
            Divider()
            QuickLookView(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct ServersView: View {
    @ObservedObject var store: ServerStore
    @State private var editing: Server?
    @State private var name = ""
    @State private var address = ""
    @State private var port = "8080"
    @State private var error: String?
    @State private var deleting: Server?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.servers) { server in
                        HStack(spacing: 12) {
                            Image(systemName: server.name.contains("笔记本") ? "laptopcomputer" : "desktopcomputer").font(.title2)
                            Button { store.select(server) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(server.name).foregroundStyle(.primary)
                                    Text(server.address).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            if store.selectedID == server.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                            Menu {
                                Button("编辑") { edit(server) }
                                Button("删除", role: .destructive) { deleting = server }
                            } label: { Image(systemName: "ellipsis") }
                        }.padding(.vertical, 6)
                    }
                }
                Section(editing == nil ? "添加服务器" : "编辑服务器") {
                    TextField("名称，例如：台式机", text: $name)
                    TextField("地址，例如：192.168.0.245", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口", text: $port).keyboardType(.numberPad)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Button { save() } label: { Text("保存").frame(maxWidth: .infinity).padding(6) }.buttonStyle(.borderedProminent)
                    if editing != nil { Button("取消编辑") { reset() } }
                }
                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    LabeledContent("构建号", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                }
                Section("使用提示") {
                    Text("把启动 BAT 放在要共享的目录内，双击启动 Caddy。在这里填写电脑的局域网 IP 和窗口显示的端口。")
                    Text("同一台电脑的不同目录可以使用不同端口，同时保存为多个服务器。切换或删除服务器不会改变已有下载任务的来源。")
                    Text("手机和电脑需要连接同一局域网。锁屏可以继续下载；请勿从多任务界面强制关闭 App。")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("服务器管理").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { reset() } label: { Image(systemName: "plus") }.accessibilityLabel("添加服务器") } }
            .alert("删除这个服务器？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("删除", role: .destructive) { if let deleting { store.delete(deleting) }; deleting = nil }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { Text("已有下载任务和文件会保留。") }
        }
    }
    private func reset() { editing = nil; name = ""; address = ""; port = "8080"; error = nil }
    private func edit(_ server: Server) {
        editing = server; name = server.name
        var components = URLComponents(string: server.address)
        port = String(components?.port ?? (components?.scheme == "https" ? 443 : 80))
        components?.port = nil
        address = components?.string ?? server.address
        error = nil
    }
    private func save() {
        do {
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw LANError(message: "请输入服务器名称") }
            let normalized = try Server.normalizedAddress(address)
            guard var parts = URLComponents(string: normalized), let number = Int(port), (1...65535).contains(number) else { throw LANError(message: "端口应为 1–65535 的数字") }
            // A port pasted with the address takes precedence; the field is used for host-only input.
            if parts.port == nil { parts.port = number }
            guard let value = parts.string else { throw LANError(message: "服务器地址无效") }
            store.save(Server(id: editing?.id ?? UUID(), name: title, address: value))
            reset()
        } catch { self.error = error.localizedDescription }
    }
}
