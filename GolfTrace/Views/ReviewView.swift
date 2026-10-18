import AVFoundation
import SwiftUI
import UIKit

/// 轨迹渲染样式（由 ShotTrace 的样式字段换算而来）
struct TraceStyle {
    var lineWidth: Double
    var color: Color
    var opacity: Double
    var bendLeft: Double
    var bendRight: Double
    var paceDeceleration: Double
}

struct ReviewView: View {
    @EnvironmentObject private var session: AppSession
    @State private var player = AVPlayer()
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 1
    @State private var isPlaying = false
    @State private var isEditing = false
    @State private var timeObserver: Any?
    @State private var displayImage: UIImage?
    /// 时间轴缩略图胶片（视频记录）
    @State private var filmstrip: [(time: TimeInterval, image: UIImage)] = []
    /// 视频帧率（帧号显示与逐帧定位）
    @State private var frameRate: Double = 30
    /// 拖动胶片条时的预览时间（松手后才真正 seek）
    @State private var scrubTime: TimeInterval?

    @State private var selectedPointID: UUID?
    @State private var draggedPointID: UUID?
    @State private var undoStack: [[TracePoint]] = []
    @State private var redoStack: [[TracePoint]] = []
    /// 进入本页时的关键点状态，供「重置」恢复
    @State private var savedPoints: [TracePoint] = []

    /// 当前展开的样式参数工具（悬浮面板），nil 表示全部收起
    @State private var activeTool: EditorTool?
    /// 等待确认的危险操作
    @State private var pendingAction: PendingAction?
    /// 轨迹几何缓存（归一化坐标）：仅随关键点/弯曲变化重算，播放逐帧只做截取与映射
    @State private var cachedGeometry: CachedGeometry?

    private struct CachedGeometry {
        let points: [TracePoint]
        let bendLeft: Double
        let bendRight: Double
        let geometry: TrajectoryGeometry
    }

    /// 取轨迹几何：命中缓存直接复用，避免每帧重复计算曲线
    private func traceGeometry(for shot: ShotRecord) -> TrajectoryGeometry {
        let points = shot.trace.sortedPoints
        if let cached = cachedGeometry,
           cached.points == points,
           cached.bendLeft == shot.trace.bendLeft,
           cached.bendRight == shot.trace.bendRight {
            return cached.geometry
        }
        let geometry = VideoGeometry.trajectoryGeometry(
            keyPoints: points.map(\.location),
            bendLeft: shot.trace.bendLeft,
            bendRight: shot.trace.bendRight
        )
        cachedGeometry = CachedGeometry(
            points: points,
            bendLeft: shot.trace.bendLeft,
            bendRight: shot.trace.bendRight,
            geometry: geometry
        )
        return geometry
    }

    private let hitRadius: CGFloat = 28
    private let undoLimit = 50
    private static let presetColors: [Color] = [.white, .yellow, .orange, .red, .green, .blue]

    enum EditorTool: String, CaseIterable, Identifiable {
        case lineWidth, bend, color, opacity
        var id: String { rawValue }
        var title: String {
            switch self {
            case .lineWidth: return "线宽"
            case .bend: return "弯曲"
            case .color: return "颜色"
            case .opacity: return "透明度"
            }
        }
        var icon: String {
            switch self {
            case .lineWidth: return "lineweight"
            case .bend: return "point.topleft.down.to.point.bottomright.curvepath"
            case .color: return "paintpalette"
            case .opacity: return "circle.lefthalf.filled"
            }
        }
    }

    enum PendingAction: String, Identifiable {
        case clearAll, resetToSaved
        var id: String { rawValue }
        var title: String {
            switch self {
            case .clearAll: return "清空轨迹"
            case .resetToSaved: return "重置关键点"
            }
        }
        var message: String {
            switch self {
            case .clearAll: return "将删除全部关键点，此操作可以撤销。"
            case .resetToSaved: return "放弃本次打开后的所有修改，回到打开时的状态。"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let shot = session.currentShot {
                videoStage(shot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) { toolParameterPanel(shot) }
                    .overlay(alignment: .top) { editingHint(shot) }
                timelineSection(shot)
                toolRow(shot)
            }
        }
        .background(Color.black)
        .navigationTitle("轨迹")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                BackButton { session.goHome() }
            }
        }
        .onAppear { loadShot() }
        .onDisappear {
            session.saveCurrentShot()
            tearDownPlayer()
        }
        .onChange(of: session.currentShot?.id) { _, _ in loadShot() }
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingAction?.title ?? "确认", role: .destructive) {
                switch pendingAction {
                case .clearAll: clearAll()
                case .resetToSaved: resetToSaved()
                case nil: break
                }
                pendingAction = nil
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction?.message ?? "")
        }
    }

    // MARK: - 预览舞台（占满剩余空间，视频按比例完整显示）

    private func videoStage(_ shot: ShotRecord) -> some View {
        let geometry = traceGeometry(for: shot)
        let sortedPoints = shot.trace.sortedPoints
        let overlayStyle = style(for: shot)
        let isVideoPlaying = shot.mediaType == .video && !isEditing
        return GeometryReader { proxy in
            let videoSize = CGSize(
                width: max(shot.trace.videoWidth, 1),
                height: max(shot.trace.videoHeight, 1)
            )
            let videoRect = VideoGeometry.aspectFitRect(
                contentSize: videoSize,
                in: CGRect(origin: .zero, size: proxy.size)
            )

            ZStack {
                Color.black
                if shot.mediaType == .video {
                    PlayerLayerView(player: player)
                } else if let displayImage {
                    Image(uiImage: displayImage)
                        .resizable()
                        .scaledToFit()
                }
                // vsync 驱动：每帧直接读播放器真实时间，末端位置分数插值 → 丝滑延伸
                TimelineView(.animation) { _ in
                    TraceOverlay(
                        points: sortedPoints,
                        geometry: geometry,
                        clipTime: isVideoPlaying ? player.currentTime().seconds : nil,
                        videoDuration: duration,
                        videoRect: videoRect,
                        style: overlayStyle,
                        selectedID: isEditing ? selectedPointID : nil,
                        showHandles: isEditing
                    )
                }
                if isEditing {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(editGesture(videoRect: videoRect))
                }
            }
        }
    }

    /// 顶部轻提示：编辑模式说明 / 空轨迹引导
    @ViewBuilder
    private func editingHint(_ shot: ShotRecord) -> some View {
        if isEditing {
            Text("点击画面加关键点 · 拖动圆点调整 · 点选后可删除")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
        } else if shot.trace.points.isEmpty {
            Text("点「编辑轨迹」在球经过的位置标记关键点")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
        }
    }

    private func style(for shot: ShotRecord) -> TraceStyle {
        TraceStyle(
            lineWidth: shot.trace.lineWidth,
            color: Color(red: shot.trace.colorRed, green: shot.trace.colorGreen, blue: shot.trace.colorBlue),
            opacity: shot.trace.opacity,
            bendLeft: shot.trace.bendLeft,
            bendRight: shot.trace.bendRight,
            paceDeceleration: shot.trace.paceDeceleration
        )
    }

    // MARK: - 时间轴与播放控制

    @ViewBuilder
    private func timelineSection(_ shot: ShotRecord) -> some View {
        if shot.mediaType == .video {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        togglePlay()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 36, height: 32)
                            .contentShape(Rectangle())
                    }
                    Button {
                        stepFrame(-1)
                    } label: {
                        Image(systemName: "backward.frame.fill")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 36, height: 32)
                            .contentShape(Rectangle())
                    }
                    Button {
                        stepFrame(1)
                    } label: {
                        Image(systemName: "forward.frame.fill")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 36, height: 32)
                            .contentShape(Rectangle())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(timeLabel)
                            .font(.caption.monospacedDigit())
                        Text(frameLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(ToolbarPalette.unselected.opacity(0.7))
                    }
                }
                .foregroundStyle(ToolbarPalette.unselected)

                // 缩略图胶片条：显示视频帧，点击/拖动定位（加载完成前用进度条兜底）
                if filmstrip.isEmpty {
                    Slider(
                        value: Binding(
                            get: { currentTime },
                            set: { seek(to: $0) }
                        ),
                        in: 0...max(duration, 0.1)
                    )
                    .tint(.accentColor)
                } else {
                    filmstripView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black)
        }
    }

    private var frameLabel: String {
        let currentFrame = Int(currentTime * frameRate + 0.5)
        let totalFrames = Int(duration * frameRate + 0.5)
        return "帧 \(currentFrame)/\(totalFrames)"
    }

    /// 缩略图胶片条：全部缩略图均分宽度，播放头随进度移动
    private func filmstripView() -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let slotWidth = width / CGFloat(max(filmstrip.count, 1))
            let progress = (scrubTime ?? currentTime) / max(duration, 0.1)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(filmstrip.indices, id: \.self) { index in
                        Image(uiImage: filmstrip[index].image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: slotWidth, height: 40)
                            .clipped()
                    }
                }
                // 播放头
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 40)
                    .offset(x: min(max(progress * width, 0), width - 2))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / max(width, 1), 0), 1)
                        scrubTime = TimeInterval(fraction) * max(duration, 0.1)
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / max(width, 1), 0), 1)
                        scrubTime = nil
                        seek(to: TimeInterval(fraction) * max(duration, 0.1))
                    }
            )
        }
        .frame(height: 40)
    }

    private var timeLabel: String {
        "\(formatTime(currentTime)) / \(formatTime(duration))"
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let tenths = Int((time - floor(time)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }

    private func togglePlay() {
        if isEditing {
            // 编辑模式中点播放：先退出编辑，避免误加关键点
            isEditing = false
        }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    /// 逐帧定位：暂停后单帧步进，便于精确标记
    private func stepFrame(_ count: Int) {
        player.pause()
        isPlaying = false
        player.currentItem?.step(byCount: count)
    }

    // MARK: - 底部工具行

    /// 工具栏配色（固定深色，不随系统外观变化，保证黑底上对比度）
    private enum ToolbarPalette {
        static let background = Color(red: 0.11, green: 0.11, blue: 0.118) // #1C1C1E
        static let unselected = Color(red: 0.72, green: 0.72, blue: 0.74) // #B8B8BD
        static let destructive = Color(red: 1.0, green: 0.42, blue: 0.39)
        static let buttonBackground = Color.white.opacity(0.08)
        static let activeBackground = Color.accentColor.opacity(0.22)
        static let hairline = Color.white.opacity(0.10)
    }

    private func toolRow(_ shot: ShotRecord) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                toolButton(
                    icon: isEditing ? "checkmark.circle.fill" : "hand.draw.fill",
                    title: isEditing ? "完成" : "编辑轨迹",
                    active: isEditing
                ) { toggleEditing() }

                toolButton(icon: "arrow.uturn.backward", title: "撤销", disabled: undoStack.isEmpty) { undo() }
                toolButton(icon: "arrow.uturn.forward", title: "重做", disabled: redoStack.isEmpty) { redo() }
                toolButton(icon: "trash", title: "删除选中", destructive: true, disabled: selectedPointID == nil) { deleteSelected() }

                ForEach(EditorTool.allCases) { tool in
                    toolButton(icon: tool.icon, title: tool.title, active: activeTool == tool) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            activeTool = activeTool == tool ? nil : tool
                        }
                    }
                }

                Menu {
                    Button(role: .destructive) {
                        pendingAction = .clearAll
                    } label: {
                        Label("清空轨迹", systemImage: "xmark.circle")
                    }
                    Button(role: .destructive) {
                        pendingAction = .resetToSaved
                    } label: {
                        Label("重置关键点", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    toolButtonLabel(icon: "ellipsis.circle", title: "更多")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(ToolbarPalette.background)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ToolbarPalette.hairline)
                .frame(height: 0.5)
        }
    }

    private func toolButton(
        icon: String,
        title: String,
        active: Bool = false,
        destructive: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolButtonLabel(icon: icon, title: title, active: active, destructive: destructive)
        }
        .buttonStyle(ToolPressStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    private func toolButtonLabel(icon: String, title: String, active: Bool = false, destructive: Bool = false) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: active ? .semibold : .medium))
            Text(title)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(active ? Color.accentColor : (destructive ? ToolbarPalette.destructive : ToolbarPalette.unselected))
        .frame(width: 56, height: 46)
        .background(
            active ? ToolbarPalette.activeBackground : ToolbarPalette.buttonBackground,
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    // MARK: - 样式参数悬浮面板（覆盖在预览区底部，不挤压视频布局）

    @ViewBuilder
    private func toolParameterPanel(_ shot: ShotRecord) -> some View {
        if let tool = activeTool {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(tool.title, systemImage: tool.icon)
                        .font(.subheadline.bold())
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { activeTool = nil }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                    }
                }
                switch tool {
                case .lineWidth:
                    styleSlider("线宽", value: traceBinding(\.lineWidth), range: 2...12)
                case .opacity:
                    styleSlider("透明度", value: traceBinding(\.opacity), range: 0.15...1)
                case .bend:
                    styleSlider("左弯", value: traceBinding(\.bendLeft), range: 0...1)
                    styleSlider("右弯", value: traceBinding(\.bendRight), range: 0...1)
                case .color:
                    colorRow(shot)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func styleSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if !editing { session.saveCurrentShot() }
            }
            .tint(.accentColor)
            Text(value.wrappedValue, format: .number.precision(.fractionLength(1)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .frame(height: 28)
    }

    private func colorRow(_ shot: ShotRecord) -> some View {
        HStack(spacing: 12) {
            ForEach(Self.presetColors, id: \.self) { color in
                Circle()
                    .fill(color)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle().stroke(
                            isCurrentColor(color, shot: shot) ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: isCurrentColor(color, shot: shot) ? 3 : 1
                        )
                    )
                    .onTapGesture { setColor(color) }
            }
            Spacer()
            ColorPicker("自定义颜色", selection: colorBinding, supportsOpacity: false)
                .font(.caption)
        }
    }

    // MARK: - 手势：点击加点 / 拖拽移动 / 点选

    private func editGesture(videoRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                // 按下瞬间做命中检测：命中关键点 → 选中并进入拖拽；否则等待松手判定为加点
                if draggedPointID == nil {
                    if let hit = hitTest(value.startLocation, videoRect: videoRect) {
                        draggedPointID = hit
                        selectedPointID = hit
                        pushUndoSnapshot()
                    }
                }
                if let id = draggedPointID {
                    movePoint(id: id, to: value.location, videoRect: videoRect)
                }
            }
            .onEnded { value in
                if let id = draggedPointID {
                    movePoint(id: id, to: value.location, videoRect: videoRect)
                    session.saveCurrentShot()
                    draggedPointID = nil
                } else if hypot(
                    value.location.x - value.startLocation.x,
                    value.location.y - value.startLocation.y
                ) < 12 {
                    // 未命中任何点且几乎没移动 → 点击空白处添加关键点
                    addPoint(at: value.location, videoRect: videoRect)
                }
            }
    }

    private func hitTest(_ location: CGPoint, videoRect: CGRect) -> UUID? {
        guard let shot = session.currentShot else { return nil }
        var best: (id: UUID, distance: CGFloat)?
        for point in shot.trace.points {
            let mapped = CGPoint(
                x: videoRect.minX + point.x * videoRect.width,
                y: videoRect.minY + point.y * videoRect.height
            )
            let distance = hypot(mapped.x - location.x, mapped.y - location.y)
            if distance <= hitRadius, best == nil || distance < best!.distance {
                best = (point.id, distance)
            }
        }
        return best?.id
    }

    private func addPoint(at location: CGPoint, videoRect: CGRect) {
        guard var shot = session.currentShot,
              let normalized = VideoGeometry.normalizedPoint(in: videoRect, from: location)
        else { return }
        pushUndoSnapshot()
        let point = TracePoint(
            time: shot.mediaType == .video ? currentTime : 0,
            x: normalized.x,
            y: normalized.y,
            source: .manual,
            sequence: shot.trace.points.count
        )
        shot.trace.points.append(point)
        selectedPointID = point.id
        session.currentShot = shot
        session.saveCurrentShot()
    }

    private func movePoint(id: UUID, to location: CGPoint, videoRect: CGRect) {
        guard var shot = session.currentShot,
              let normalized = VideoGeometry.clampedNormalizedPoint(in: videoRect, from: location),
              let index = shot.trace.points.firstIndex(where: { $0.id == id })
        else { return }
        shot.trace.points[index].x = normalized.x
        shot.trace.points[index].y = normalized.y
        session.currentShot = shot
    }

    private func deleteSelected() {
        guard var shot = session.currentShot, let id = selectedPointID else { return }
        pushUndoSnapshot()
        shot.trace.points.removeAll { $0.id == id }
        selectedPointID = nil
        session.currentShot = shot
        session.saveCurrentShot()
    }

    private func clearAll() {
        guard var shot = session.currentShot, !shot.trace.points.isEmpty else { return }
        pushUndoSnapshot()
        shot.trace.points = []
        selectedPointID = nil
        session.currentShot = shot
        session.saveCurrentShot()
    }

    /// 放弃本次打开后的所有修改，回到进入本页时的状态
    private func resetToSaved() {
        guard var shot = session.currentShot else { return }
        undoStack.removeAll()
        redoStack.removeAll()
        shot.trace.points = savedPoints
        selectedPointID = nil
        session.currentShot = shot
        session.saveCurrentShot()
    }

    // MARK: - 撤销 / 重做

    private func pushUndoSnapshot() {
        guard let shot = session.currentShot else { return }
        undoStack.append(shot.trace.points)
        if undoStack.count > undoLimit {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    private func undo() {
        guard var shot = session.currentShot, let previous = undoStack.popLast() else { return }
        redoStack.append(shot.trace.points)
        if redoStack.count > undoLimit {
            redoStack.removeFirst()
        }
        shot.trace.points = previous
        selectedPointID = nil
        session.currentShot = shot
        session.saveCurrentShot()
    }

    private func redo() {
        guard var shot = session.currentShot, let next = redoStack.popLast() else { return }
        undoStack.append(shot.trace.points)
        shot.trace.points = next
        selectedPointID = nil
        session.currentShot = shot
        session.saveCurrentShot()
    }

    // MARK: - 样式绑定

    private func traceBinding(_ keyPath: WritableKeyPath<ShotTrace, Double>) -> Binding<Double> {
        Binding(
            get: { session.currentShot?.trace[keyPath: keyPath] ?? 0 },
            set: { newValue in
                guard var shot = session.currentShot else { return }
                shot.trace[keyPath: keyPath] = newValue
                session.currentShot = shot
            }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                guard let trace = session.currentShot?.trace else { return .yellow }
                return Color(red: trace.colorRed, green: trace.colorGreen, blue: trace.colorBlue)
            },
            set: { newColor in
                let uiColor = UIColor(newColor)
                var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
                uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                guard var shot = session.currentShot else { return }
                shot.trace.colorRed = Double(red)
                shot.trace.colorGreen = Double(green)
                shot.trace.colorBlue = Double(blue)
                session.currentShot = shot
                session.saveCurrentShot()
            }
        )
    }

    private func isCurrentColor(_ color: Color, shot: ShotRecord) -> Bool {
        let uiColor = UIColor(color)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return abs(Double(red) - shot.trace.colorRed) < 0.02
            && abs(Double(green) - shot.trace.colorGreen) < 0.02
            && abs(Double(blue) - shot.trace.colorBlue) < 0.02
    }

    private func setColor(_ color: Color) {
        colorBinding.wrappedValue = color
    }

    // MARK: - 模式切换

    private func toggleEditing() {
        isEditing.toggle()
        if isEditing {
            player.pause()
            isPlaying = false
            selectedPointID = nil
            activeTool = nil
        }
    }

    // MARK: - 播放器与加载

    private func loadShot() {
        guard let shot = session.currentShot else { return }
        savedPoints = shot.trace.points
        undoStack.removeAll()
        redoStack.removeAll()
        selectedPointID = nil
        draggedPointID = nil
        activeTool = nil
        isEditing = false
        currentTime = 0
        if shot.mediaType == .video {
            displayImage = nil
            loadPlayer()
        } else {
            tearDownPlayer()
            displayImage = UIImage(contentsOfFile: shot.mediaURL.path)
        }
#if DEBUG
        applyDebugArguments()
#endif
    }

#if DEBUG
    /// 仅调试用：-autoEdit 直接进入编辑模式；-autoPanel=xxx 预展开参数面板
    private func applyDebugArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-autoEdit") {
            isEditing = true
            player.pause()
            isPlaying = false
        }
        if let panelArg = arguments.first(where: { $0.hasPrefix("-autoPanel=") }) {
            let name = panelArg.components(separatedBy: "=").last ?? ""
            activeTool = EditorTool.allCases.first { $0.rawValue == name }
        }
    }
#endif

    private func loadPlayer() {
        guard let shot = session.currentShot, shot.mediaType == .video else { return }
        filmstrip = []
        scrubTime = nil
        let item = AVPlayerItem(url: shot.mediaURL)
        player.replaceCurrentItem(with: item)
        // 60Hz 驱动：轨迹延伸端在高刷屏上平滑移动，不显阶梯
        let interval = CMTime(value: 1, timescale: 60)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = time.seconds
        }
        Task {
            if let durationTime = try? await item.asset.load(.duration) {
                let seconds = durationTime.seconds
                duration = seconds.isFinite && seconds > 0 ? seconds : 1
            }
            if let track = try? await item.asset.loadTracks(withMediaType: .video).first {
                let rate = (try? await track.load(.nominalFrameRate)) ?? 30
                frameRate = rate > 0 ? Double(rate) : 30
            }
            // 缩略图胶片：后台生成，避免阻塞播放
            let url = shot.mediaURL
            let videoDuration = duration
            let thumbs = await Task.detached(priority: .utility) {
                Self.generateFilmstrip(for: url, duration: videoDuration)
            }.value
            filmstrip = thumbs
        }
        player.play()
        isPlaying = true
    }

    /// 沿视频等距抽取 16 帧缩略图，供时间轴胶片条显示
    private static func generateFilmstrip(for url: URL, duration: TimeInterval) -> [(TimeInterval, UIImage)] {
        guard duration > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        let count = 16
        let spacing = duration / Double(count)
        var results: [(TimeInterval, UIImage)] = []
        results.reserveCapacity(count)
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) * spacing + spacing / 2, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                results.append((time.seconds, UIImage(cgImage: cgImage)))
            }
        }
        return results
    }

    private func tearDownPlayer() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
        isPlaying = false
    }

    private func seek(to time: TimeInterval) {
        currentTime = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

}

/// 工具栏按钮按下反馈：轻微缩小 + 变暗，松开恢复
struct ToolPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 左上角返回按钮：横向深黑胶囊，内部仅一个电光蓝左箭头。
/// 极简冷峻，与黑色编辑界面融为一体。
struct BackButton: View {
    var action: () -> Void

    /// 电光蓝箭头强调色
    private let arrowColor = Color(red: 0.25, green: 0.66, blue: 1.0)

    var body: some View {
        Button(action: action) {
            // 唯一一层背景：深黑胶囊底板；箭头直接置于其上，无描边、无阴影、无叠加层
            Image(systemName: "chevron.backward")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(arrowColor)
                .frame(width: 60, height: 36)
                .background(Color.black.opacity(0.55), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(BackButtonPressStyle())
    }
}

/// 返回按钮按压反馈：轻微缩小 + 背景微亮，松开平滑恢复
struct BackButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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
    /// 全部关键点（按时间排序），供弧长-时间映射使用
    let points: [TracePoint]
    /// 预计算的轨迹几何（归一化坐标）：由外层缓存，播放逐帧不重算
    let geometry: TrajectoryGeometry
    /// 播放时间裁切：nil = 绘制完整曲线（编辑模式/图片）；否则曲线沿路径生长到该时刻
    let clipTime: TimeInterval?
    /// 视频总时长：用于在视频结束前完成轨迹绘制
    let videoDuration: TimeInterval
    let videoRect: CGRect
    let style: TraceStyle
    let selectedID: UUID?
    let showHandles: Bool

    /// 按分数采样位置截取并映射到视图坐标；末端在相邻采样点之间线性插值，
    /// 保证轨迹末端每帧连续移动、慢速阶段无顿挫。
    private func mappedPathPoints(count: Double) -> [CGPoint] {
        let samples = geometry.samples
        let whole = min(Int(count.rounded(.down)), samples.count)
        var points = samples.prefix(whole).map {
            CGPoint(
                x: videoRect.minX + $0.x * videoRect.width,
                y: videoRect.minY + $0.y * videoRect.height
            )
        }
        let fraction = count - Double(whole)
        if fraction > 0.0001 {
            if whole == 0, samples.count >= 2 {
                // 轨迹起点：在第一个采样点与其后一点之间插值
                points.append(CGPoint(
                    x: videoRect.minX + (samples[0].x + (samples[1].x - samples[0].x) * fraction) * videoRect.width,
                    y: videoRect.minY + (samples[0].y + (samples[1].y - samples[0].y) * fraction) * videoRect.height
                ))
            } else if whole > 0, whole < samples.count {
                let a = samples[whole - 1]
                let b = samples[whole]
                points.append(CGPoint(
                    x: videoRect.minX + (a.x + (b.x - a.x) * fraction) * videoRect.width,
                    y: videoRect.minY + (a.y + (b.y - a.y) * fraction) * videoRect.height
                ))
            }
        }
        return points
    }

    var body: some View {
        Canvas { context, _ in
            // 曲线绘制：逐帧仅做「弧长截取 + 坐标映射 + 路径构建」，几何零重算
            if geometry.samples.count >= 2 {
                var pathPoints: [CGPoint] = []
                var drawAll = true
                if let clipTime {
                    if let count = VideoGeometry.drawSampleCount(
                        geometry: geometry,
                        keyPoints: points,
                        clipTime: clipTime,
                        paceDeceleration: style.paceDeceleration,
                        videoDuration: videoDuration
                    ) {
                        guard count > 0 else { return }
                        drawAll = false
                        pathPoints = mappedPathPoints(count: count)
                    }
                }
                if drawAll {
                    pathPoints = geometry.samples.map {
                        CGPoint(x: videoRect.minX + $0.x * videoRect.width,
                                y: videoRect.minY + $0.y * videoRect.height)
                    }
                }
                if pathPoints.count >= 2 {
                    var path = Path()
                    path.move(to: pathPoints[0])
                    // 连续三次 Bézier 曲线渲染：相邻段共享切线，整条轨迹无折线
                    for segment in VideoGeometry.bezierSegments(pathPoints) {
                        path.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
                    }
                    // 光晕层：更宽、低透明度，与主线同步延伸
                    context.stroke(
                        path,
                        with: .color(style.color.opacity(style.opacity * 0.22)),
                        style: StrokeStyle(
                            lineWidth: max(style.lineWidth * 2.6, 6),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    // 主线：清晰锐利
                    context.stroke(
                        path,
                        with: .color(style.color.opacity(style.opacity)),
                        style: StrokeStyle(
                            lineWidth: max(style.lineWidth, 1),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
                // 球当前位置：柔光晕 + 清晰圆点，随曲线末端移动
                if let last = pathPoints.last {
                    let halo = Path(ellipseIn: CGRect(x: last.x - 12, y: last.y - 12, width: 24, height: 24))
                    context.fill(halo, with: .color(style.color.opacity(style.opacity * 0.25)))
                    let dot = Path(ellipseIn: CGRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10))
                    context.fill(dot, with: .color(.orange))
                }
            }

            // 编辑模式：关键点手柄（视觉小圆点，触控区域由 ReviewView 的 hitRadius 保证）
            if showHandles {
                for point in points {
                    let mapped = CGPoint(
                        x: videoRect.minX + point.x * videoRect.width,
                        y: videoRect.minY + point.y * videoRect.height
                    )
                    let isSelected = point.id == selectedID
                    let radius: CGFloat = isSelected ? 6 : 4
                    let rect = CGRect(
                        x: mapped.x - radius,
                        y: mapped.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(isSelected ? .orange : .white))
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(isSelected ? .white : .black.opacity(0.35)),
                        lineWidth: isSelected ? 1.5 : 0.8
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
