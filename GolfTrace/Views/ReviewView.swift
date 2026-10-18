import AVFoundation
import SwiftUI
import UIKit

struct ReviewView: View {
    @EnvironmentObject private var session: AppSession
    @State private var player = AVPlayer()
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 1
    @State private var isEditing = false
    @State private var isExporting = false
    @State private var toast: String?
    @State private var timeObserver: Any?

    private let exporter = VideoExporter()

    var body: some View {
        VStack(spacing: 0) {
            if let shot = session.currentShot {
                videoStage(shot)
                controls(shot)
            }
        }
        .navigationTitle("轨迹")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { session.goHome() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "完成描点" : "手动描点") {
                    isEditing.toggle()
                    if isEditing {
                        player.pause()
                    }
                }
            }
        }
        .onAppear { loadPlayer() }
        .onDisappear { tearDownPlayer() }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
            }
        }
    }

    private func videoStage(_ shot: ShotRecord) -> some View {
        GeometryReader { proxy in
            let videoSize = CGSize(
                width: max(shot.trace.videoWidth, 1),
                height: max(shot.trace.videoHeight, 1)
            )
            let videoRect = VideoGeometry.aspectFitRect(contentSize: videoSize, in: CGRect(origin: .zero, size: proxy.size))

            ZStack {
                Color.black
                PlayerLayerView(player: player)
                TraceOverlay(points: shot.trace.points(upTo: currentTime), videoRect: videoRect)

                if isEditing {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    addManualPoint(at: value.location, videoRect: videoRect)
                                }
                        )
                }
            }
        }
        .aspectRatio(
            max(session.currentShot?.trace.videoWidth ?? 9, 1) /
                max(session.currentShot?.trace.videoHeight ?? 16, 1),
            contentMode: .fit
        )
        .background(Color.black)
    }

    private func controls(_ shot: ShotRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            statusText(shot)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { seek(to: $0) }
                ),
                in: 0...max(duration, 0.1)
            )

            HStack {
                Button {
                    player.rate == 0 ? player.play() : player.pause()
                } label: {
                    Image(systemName: "playpause.fill")
                        .frame(width: 44, height: 44)
                }

                Button("撤销点") {
                    undoPoint()
                }
                .disabled(shot.trace.points.isEmpty)

                Spacer()

                Button {
                    Task { await export() }
                } label: {
                    if isExporting {
                        ProgressView()
                    } else {
                        Label("导出到相册", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting || shot.trace.points.count < 2)
            }
        }
        .padding()
    }

    private func statusText(_ shot: ShotRecord) -> Text {
        if shot.trace.hasAutomaticPoints {
            return Text("已自动识别 \(shot.trace.points.filter { $0.source == .automatic }.count) 个点。轨迹不准可以手动描点。")
        }
        if shot.trace.points.isEmpty {
            return Text("没有检测到球路。暂停画面，在球的位置点几下。")
        }
        return Text("当前是手动画的轨迹，共 \(shot.trace.points.count) 个点。")
    }

    private func addManualPoint(at location: CGPoint, videoRect: CGRect) {
        guard var shot = session.currentShot,
              let normalized = VideoGeometry.normalizedPoint(in: videoRect, from: location)
        else { return }
        shot.trace.points.append(
            TracePoint(time: currentTime, x: normalized.x, y: normalized.y, source: .manual)
        )
        session.currentShot = shot
        session.saveCurrentShot()
    }

    private func undoPoint() {
        guard var shot = session.currentShot, !shot.trace.points.isEmpty else { return }
        let sorted = shot.trace.sortedPoints
        guard let last = sorted.last else { return }
        shot.trace.points.removeAll { $0.id == last.id }
        session.currentShot = shot
        session.saveCurrentShot()
    }

    private func loadPlayer() {
        guard let shot = session.currentShot else { return }
        let item = AVPlayerItem(url: shot.videoURL)
        player.replaceCurrentItem(with: item)
        let interval = CMTime(seconds: 0.03, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = time.seconds
        }
        Task {
            if let durationTime = try? await item.asset.load(.duration) {
                let seconds = durationTime.seconds
                duration = seconds.isFinite && seconds > 0 ? seconds : 1
            }
        }
        player.play()
    }

    private func tearDownPlayer() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
    }

    private func seek(to time: TimeInterval) {
        currentTime = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func export() async {
        guard let shot = session.currentShot else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            try await exporter.exportToPhotos(shot: shot)
            toast = "已保存到相册"
            try await Task.sleep(for: .seconds(2))
            toast = nil
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

struct TraceOverlay: View {
    let points: [TracePoint]
    let videoRect: CGRect

    var body: some View {
        Canvas { context, _ in
            guard points.count >= 1 else { return }
            let mapped = points.map {
                CGPoint(
                    x: videoRect.minX + $0.x * videoRect.width,
                    y: videoRect.minY + $0.y * videoRect.height
                )
            }

            if mapped.count >= 2 {
                var path = Path()
                path.addLines(mapped)
                context.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [Color.yellow, Color.orange]),
                        startPoint: mapped.first!,
                        endPoint: mapped.last!
                    ),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
            }

            if let last = mapped.last {
                let dot = Path(ellipseIn: CGRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10))
                context.fill(dot, with: .color(.orange))
            }
        }
        .allowsHitTesting(false)
    }
}
