import SwiftUI
import AVFoundation
import KSPlayer

// Two playback engines; the FFmpeg engine also exposes a software decoding mode.
enum PlaybackEngine: String, CaseIterable, Identifiable {
    case native = "系统引擎", ffmpeg = "FFmpeg · 硬解优先", software = "FFmpeg · 软件解码"
    var id: String { rawValue }
    static func initial(for name: String) -> PlaybackEngine {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "3gp"].contains(ext) ? .native : .ffmpeg
    }
    var fallback: PlaybackEngine? {
        switch self { case .native: return .ffmpeg; case .ffmpeg: return .software; case .software: return nil }
    }
}

@MainActor
final class FloatingVideoSession: NSObject, ObservableObject, KSPlayerLayerDelegate {
    let access: LocalFileAccess
    @Published private(set) var engine: PlaybackEngine = .native
    @Published private(set) var surface: UIView?
    @Published private(set) var playing = false
    @Published private(set) var loading = true
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var failure: String?
    @Published private(set) var rate: Float = 1
    @Published var expanded = false
    private var layer: KSPlayerLayer?
    private var startupTimeout: Task<Void, Never>?
    private var generation = UUID()
    private var pendingSeek: Double?
    private var stopped = false
    private var mayFallback = true
    private let previousFallback = KSOptions.secondPlayerType
    private var savedIdleTimer: Bool
    init(access: LocalFileAccess) {
        self.access = access
        savedIdleTimer = UIApplication.shared.isIdleTimerDisabled
        super.init()
        configure(PlaybackEngine.initial(for: access.url.lastPathComponent), at: 0, autoplay: true)
    }
    private func configure(_ engine: PlaybackEngine, at time: Double, autoplay: Bool) {
        startupTimeout?.cancel()
        generation = UUID()
        layer?.delegate = nil
        layer?.pause()
        layer?.stop()
        layer = nil
        surface = nil
        self.engine = engine
        pendingSeek = time > 0 ? time : nil
        failure = nil
        loading = true
        // Restore globals after construction: this session alone owns engine selection.
        let previousFirst = KSOptions.firstPlayerType
        KSOptions.firstPlayerType = engine == .native ? KSAVPlayer.self : KSMEPlayer.self
        KSOptions.secondPlayerType = nil
        defer {
            KSOptions.firstPlayerType = previousFirst
        }
        let options = KSOptions()
        options.hardwareDecode = engine != .software
        options.startPlayTime = time.isFinite ? max(0, time) : 0
        options.startPlayRate = rate
        options.registerRemoteControll = false
        let newLayer = KSPlayerLayer(url: access.url, isAutoPlay: false, options: options)
        layer = newLayer
        newLayer.delegate = self
        surface = newLayer.player.view
        playing = autoplay
        let token = generation
        startupTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            guard let self, !self.stopped, self.generation == token,
                  self.layer?.player.isReadyToPlay != true else { return }
            self.handleFailure("打开视频超时。文件可能尚未完整下载，或当前引擎无法解析其编码。")
        }
        if autoplay { newLayer.play() }
        else { newLayer.prepareToPlay() }
    }
    func select(_ engine: PlaybackEngine) {
        guard !stopped else { return }
        mayFallback = false
        configure(engine, at: elapsed, autoplay: failure != nil || playing)
    }
    func toggle() {
        guard failure == nil, let layer else { return }
        let shouldPlay = !playing
        if shouldPlay { layer.play() } else { layer.pause() }
        playing = shouldPlay
    }
    func seek(to value: Double) {
        guard let layer, duration > 0, value.isFinite else { return }
        layer.seek(time: min(max(value, 0), duration), autoPlay: playing) { _ in }
    }
    func setRate(_ value: Float) { rate = value; layer?.player.playbackRate = value }
    func retry() { configure(engine, at: elapsed, autoplay: true) }
    func pauseForBackground() { layer?.pause(); playing = false }
    func close() {
        guard !stopped else { return }
        stopped = true
        startupTimeout?.cancel()
        startupTimeout = nil
        layer?.delegate = nil
        layer?.pause()
        layer?.stop()
        layer = nil
        surface = nil
        KSOptions.secondPlayerType = previousFallback
        UIApplication.shared.isIdleTimerDisabled = savedIdleTimer
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard self.layer === layer, !stopped else { return }
        if state == .readyToPlay {
            startupTimeout?.cancel()
            startupTimeout = nil
            duration = layer.player.duration.isFinite ? max(0, layer.player.duration) : 0
            if let target = pendingSeek {
                pendingSeek = nil
                DispatchQueue.main.async { [weak self, weak layer] in
                    guard let self, let layer, self.layer === layer, !self.stopped else { return }
                    layer.seek(time: target, autoPlay: self.playing) { _ in }
                }
            }
        }
        loading = state == .preparing || state == .buffering
        if state == .paused || state == .playedToTheEnd { playing = false }
        if state == .bufferFinished { playing = true }
    }
    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard self.layer === layer, !stopped else { return }
        elapsed = currentTime.isFinite ? max(0, currentTime) : 0
        duration = totalTime.isFinite ? max(0, totalTime) : 0
    }
    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard self.layer === layer, !stopped else { return }
        loading = false
        playing = false
        guard let error else { return }
        handleFailure(error.localizedDescription)
    }
    private func handleFailure(_ message: String) {
        startupTimeout?.cancel()
        startupTimeout = nil
        loading = false
        playing = false
        let token = generation
        if mayFallback, let next = engine.fallback {
            // Do not tear down a player while its delegate callback is executing.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.generation == token else { return }
                self.configure(next, at: self.elapsed, autoplay: true)
            }
        } else {
            layer?.pause()
            failure = "无法打开视频（\(engine.rawValue)）。可重试、切换引擎，或通过分享交给其他播放器。\n" + message
        }
    }
    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
}

private struct PlaybackSurface: UIViewRepresentable {
    let surface: UIView?
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.backgroundColor = .black; return view }
    func updateUIView(_ view: UIView, context: Context) {
        guard view.subviews.first !== surface else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        guard let surface else { return }
        surface.removeFromSuperview()
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

struct FloatingVideoPlayer: View {
    @ObservedObject var session: FloatingVideoSession
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var sharing = false
    @State private var scrubbing = false
    @State private var scrubTime: Double = 0
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                ZStack {
                    PlaybackSurface(surface: session.surface)
                    if session.loading { ProgressView().tint(.white).allowsHitTesting(false) }
                    if let error = session.failure {
                        VStack(spacing: 8) {
                            Text(error).font(.caption).lineLimit(4)
                            Button("重试") { session.retry() }.buttonStyle(.bordered)
                        }.padding().background(.black.opacity(0.8))
                    }
                }.frame(height: session.expanded ? max(80, geometry.size.height - 110) : min(geometry.size.width * 9 / 16, max(80, geometry.size.height - 110)))
                controls
            }
            .foregroundStyle(.white).background(.black)
            .clipShape(RoundedRectangle(cornerRadius: session.expanded ? 0 : 14))
            .shadow(radius: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .sheet(isPresented: $sharing) { FileShareView(access: session.access) }
        .onChange(of: scenePhase) { phase in if phase != .active { session.pauseForBackground() } }
    }
    private var header: some View {
        HStack(spacing: 4) {
            Button { session.close(); onClose() } label: { Image(systemName: "xmark").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("关闭播放器")
            Text(session.access.url.lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Menu {
                ForEach(PlaybackEngine.allCases) { engine in
                    Button { session.select(engine) } label: {
                        if engine == session.engine { Label(engine.rawValue, systemImage: "checkmark") }
                        else { Text(engine.rawValue) }
                    }
                }
            } label: { Text(session.engine == .native ? "系统" : (session.engine == .software ? "软解" : "FFmpeg")).font(.caption).frame(minWidth: 48, minHeight: 44) }.accessibilityLabel("切换播放引擎")
            Menu {
                ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                    Button("\(rate.formatted())×") { session.setRate(rate) }
                }
            } label: { Text("\(session.rate.formatted())×").font(.caption).frame(minWidth: 36, minHeight: 44) }.accessibilityLabel("播放速度")
            Button { sharing = true } label: { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.accessibilityLabel("分享视频")
        }.padding(.horizontal, 4).frame(height: 50)
    }
    private var controls: some View {
        HStack(spacing: 6) {
            Button { session.toggle() } label: { Image(systemName: session.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }.disabled(session.failure != nil).accessibilityLabel(session.playing ? "暂停" : "播放")
            Text(clock(scrubbing ? scrubTime : session.elapsed)).font(.caption2).monospacedDigit()
            Slider(value: Binding(get: { scrubbing ? scrubTime : min(session.elapsed, max(1, session.duration)) }, set: { scrubTime = $0 }), in: 0...max(1, session.duration), onEditingChanged: { editing in
                if editing { scrubTime = session.elapsed; scrubbing = true }
                else { scrubbing = false; session.seek(to: scrubTime) }
            }).tint(.white).disabled(session.duration <= 0).accessibilityLabel("播放进度")
            Text(clock(session.duration)).font(.caption2).monospacedDigit()
            Button { session.expanded.toggle() } label: { Image(systemName: session.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }.accessibilityLabel(session.expanded ? "缩小播放器" : "放大播放器")
        }.padding(.horizontal, 4).frame(height: 54)
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(min(max(value.isFinite ? value : 0, 0), 359999))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
