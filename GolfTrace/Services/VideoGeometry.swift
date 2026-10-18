import AVFoundation
import CoreGraphics
import ImageIO

/// 轨迹几何结果：平滑采样点 + 弧长参数化数据（用于按弧长做动画进度）
struct TrajectoryGeometry {
    /// 平滑采样点（含全局弯曲后的最终路径）
    var samples: [CGPoint]
    /// 每个采样点的累计弧长（与 samples 一一对应）
    var cumulativeLengths: [Double]
    /// 每个关键点处的累计弧长（与关键点一一对应）
    var keyCumulativeLengths: [Double]
}

enum VideoGeometry {
    static func displaySize(for track: AVAssetTrack) -> CGSize {
        let size = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    static func orientation(from transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0):
            return .right
        case (0, -1, 1, 0):
            return .left
        case (-1, 0, 0, -1):
            return .down
        default:
            return .up
        }
    }

    static func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else { return bounds }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        let origin = CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        return CGRect(origin: origin, size: size)
    }

    static func normalizedPoint(in videoRect: CGRect, from viewPoint: CGPoint) -> CGPoint? {
        guard videoRect.contains(viewPoint), videoRect.width > 0, videoRect.height > 0 else { return nil }
        return CGPoint(
            x: (viewPoint.x - videoRect.minX) / videoRect.width,
            y: (viewPoint.y - videoRect.minY) / videoRect.height
        )
    }

    /// 拖拽用：把视图坐标转成归一化坐标并 clamp 到 [0,1]。
    /// 与 normalizedPoint 不同，允许手指拖出画面边缘时点贴边移动而不是卡住。
    static func clampedNormalizedPoint(in videoRect: CGRect, from viewPoint: CGPoint) -> CGPoint? {
        guard videoRect.width > 0, videoRect.height > 0 else { return nil }
        return CGPoint(
            x: min(max((viewPoint.x - videoRect.minX) / videoRect.width, 0), 1),
            y: min(max((viewPoint.y - videoRect.minY) / videoRect.height, 0), 1)
        )
    }

    /// 每段关键点之间的采样密度
    static let trajectoryStepsPerSegment = 16

    /// 根据全部关键点生成平滑轨迹采样点：基础曲线 + 全局弯曲，两遍式计算。
    /// 第一遍：所有关键点作为一条完整路径，用 Fritsch–Carlson 风格切线 + Hermite 插值
    /// 生成基础曲线，同时记录每个采样点和每个关键点处的累计弧长。
    /// 第二遍：全局弯曲——左弯/右弯合并为单一有符号强度 b = bendRight − bendLeft，
    /// 用全局包络 sin(π·t) 对整条曲线统一施加水平偏移：起点终点偏移为 0、中间最大，
    /// 形成一条连续的大弧线；所有段共享同一套全局弯曲参数，不做逐段弯曲。
    /// 坐标系无关：输入输出同一坐标系，调用方用归一化或像素坐标均可。
    static func trajectoryGeometry(
        keyPoints: [CGPoint],
        bendLeft: Double,
        bendRight: Double
    ) -> TrajectoryGeometry {
        guard keyPoints.count >= 2 else {
            return TrajectoryGeometry(samples: keyPoints, cumulativeLengths: [], keyCumulativeLengths: [])
        }
        let n = keyPoints.count
        // 全局弯曲强度：左负右正，单一有符号值。
        // 0.8 次幂映射：低中档位弧度更明显、档位差异清晰；最大档位仍为 1，不放大避免回环。
        let bend = bendRight - bendLeft
        let bendStrength = bend >= 0 ? pow(bend, 0.8) : -pow(-bend, 0.8)

        // 第一步：全局计算每个关键点的切线（Fritsch–Carlson 形状保持插值）
        // - 方向 = 相邻弦之和（天然落在转折楔形内，转弯处形成宽润圆弧）；
        // - 逐维形状保持：x/y 局部极值点（最高点、最低点、横向转折点）对应切线分量置 0，
        //   曲线在极值处恰好转向、切线水平/竖直，不产生过冲鼓包；
        // - 幅度设上限防过冲；两分量同为 0（双向折返）时用角平分线方向兜底。
        var tangents: [CGPoint] = []
        tangents.reserveCapacity(n)
        for i in 0..<n {
            let pPrev = keyPoints[max(i - 1, 0)]
            let pNext = keyPoints[min(i + 1, n - 1)]
            if i == 0 || i == n - 1 {
                // 端点：指向相邻点的半弦，平滑起止
                tangents.append(CGPoint(
                    x: (pNext.x - pPrev.x) / 2,
                    y: (pNext.y - pPrev.y) / 2
                ))
            } else {
                let v1 = CGPoint(x: keyPoints[i].x - pPrev.x, y: keyPoints[i].y - pPrev.y)
                let v2 = CGPoint(x: pNext.x - keyPoints[i].x, y: pNext.y - keyPoints[i].y)
                let l1 = hypot(v1.x, v1.y)
                let l2 = hypot(v2.x, v2.y)
                var tangent = CGPoint(x: (v1.x + v2.x) / 2, y: (v1.y + v2.y) / 2)
                if l1 > 0.0001, l2 > 0.0001 {
                    // 形状保持：局部极值处对应分量处理
                    let isXExtremum = (keyPoints[i].x <= pPrev.x && keyPoints[i].x <= pNext.x)
                        || (keyPoints[i].x >= pPrev.x && keyPoints[i].x >= pNext.x)
                    let isYExtremum = (keyPoints[i].y <= pPrev.y && keyPoints[i].y <= pNext.y)
                        || (keyPoints[i].y >= pPrev.y && keyPoints[i].y >= pNext.y)
                    if isYExtremum {
                        // 顶点/谷底：切线保持水平（无垂直过冲），
                        // 横向沿弦和方向小幅扫过（限幅），顶点舒展圆润而非平顶
                        tangent.y = 0
                        let lateralCap = 0.5 * min(l1, l2)
                        tangent.x = min(max(tangent.x, -lateralCap), lateralCap)
                    } else if isXExtremum {
                        // 横向转折点（非顶点）：切线竖直，平滑转向
                        tangent.x = 0
                    }
                    let magnitude = hypot(tangent.x, tangent.y)
                    if magnitude < 0.0001 * min(l1, l2) {
                        // 双向折返且非顶点（两分量都为 0）：角平分线方向 + 中等幅度圆润绕过
                        let u1 = CGPoint(x: v1.x / l1, y: v1.y / l1)
                        let u2 = CGPoint(x: v2.x / l2, y: v2.y / l2)
                        var bisector = CGPoint(x: u1.x + u2.x, y: u1.y + u2.y)
                        let bisectorLength = hypot(bisector.x, bisector.y)
                        if bisectorLength < 0.0001 {
                            bisector = CGPoint(x: -u1.y, y: u1.x)
                        } else {
                            bisector = CGPoint(x: bisector.x / bisectorLength, y: bisector.y / bisectorLength)
                        }
                        tangent = CGPoint(
                            x: bisector.x * 0.5 * min(l1, l2),
                            y: bisector.y * 0.5 * min(l1, l2)
                        )
                    } else {
                        // 幅度上限放宽到 2.5×min：等长段（常规情况）不再被约束，
                        // 曲线保持自然的弦和切线、弧线舒展；仅极端不等长时约束短边防回环
                        let cap = 2.5 * min(l1, l2)
                        if magnitude > cap {
                            let ratio = cap / magnitude
                            tangent = CGPoint(x: tangent.x * ratio, y: tangent.y * ratio)
                        }
                    }
                }
                tangents.append(tangent)
            }
        }

        // 第二步：基础曲线采样（无弯曲），记录采样点与关键点的累计弧长
        let steps = trajectoryStepsPerSegment
        var baseSamples: [CGPoint] = []
        var cumulativeLengths: [Double] = []
        var keyCumulativeLengths: [Double] = []
        baseSamples.reserveCapacity((n - 1) * steps + 1)
        cumulativeLengths.reserveCapacity((n - 1) * steps + 1)
        keyCumulativeLengths.reserveCapacity(n)
        var totalLength = 0.0

        for i in 0..<(n - 1) {
            // 段起点即关键点 i，记录其累计弧长
            keyCumulativeLengths.append(totalLength)
            let p1 = keyPoints[i]
            let p2 = keyPoints[i + 1]
            let m1 = tangents[i]
            let m2 = tangents[i + 1]

            for step in 0..<steps {
                let u = CGFloat(step) / CGFloat(steps)
                let point = hermitePoint(p1: p1, p2: p2, m1: m1, m2: m2, t: u)
                if let previous = baseSamples.last {
                    totalLength += hypot(point.x - previous.x, point.y - previous.y)
                }
                baseSamples.append(point)
                cumulativeLengths.append(totalLength)
            }
        }
        let lastPoint = keyPoints[n - 1]
        if let previous = baseSamples.last {
            totalLength += hypot(lastPoint.x - previous.x, lastPoint.y - previous.y)
        }
        baseSamples.append(lastPoint)
        cumulativeLengths.append(totalLength)
        keyCumulativeLengths.append(totalLength)

        // 第三步：全局弯曲——整条曲线统一偏移，形成一条大弧线
        let minX = keyPoints.map(\.x).min() ?? 0
        let maxX = keyPoints.map(\.x).max() ?? 1
        let minY = keyPoints.map(\.y).min() ?? 0
        let maxY = keyPoints.map(\.y).max() ?? 1
        let chordLength = hypot(
            keyPoints[n - 1].x - keyPoints[0].x,
            keyPoints[n - 1].y - keyPoints[0].y
        )
        let diagonal = hypot(maxX - minX, maxY - minY)
        // 幅度以整体起点→终点距离为基准（过短时按包围盒对角线兜底）
        let amplitude = 0.28 * max(chordLength, diagonal * 0.3)

        var samples = baseSamples
        if bendStrength != 0, totalLength > 0.0001 {
            for index in samples.indices {
                let t = cumulativeLengths[index] / totalLength
                // sin²(πt) 包络：两端斜率为 0，起点终点沿基础方向自然进出，
                // 强弯曲不会在起止区域与基础曲线方向对抗产生反向弯折
                let envelope = sin(.pi * t)
                let offset = bendStrength * envelope * envelope * amplitude
                samples[index].x = baseSamples[index].x + offset
            }
        }

        // clamp：x 按弯曲幅度放宽，y 限制在包围盒内，避免越出合理范围
        for index in samples.indices {
            samples[index].x = min(max(samples[index].x, minX - amplitude), maxX + amplitude)
            samples[index].y = min(max(samples[index].y, minY), maxY)
        }

        // 方向保持：最终曲线的 x 方向变化只能出现在基础曲线自身变向处。
        // 弯曲偏移不允许在基础曲线前进的区域制造反向弯折（如强左弯时起点区域的左勾）。
        for index in 1..<samples.count {
            let baseDelta = baseSamples[index].x - baseSamples[index - 1].x
            let finalDelta = samples[index].x - samples[index - 1].x
            if (baseDelta >= 0 && finalDelta < 0) || (baseDelta <= 0 && finalDelta > 0) {
                samples[index].x = samples[index - 1].x
            }
        }

        return TrajectoryGeometry(
            samples: samples,
            cumulativeLengths: cumulativeLengths,
            keyCumulativeLengths: keyCumulativeLengths
        )
    }

    /// 把密集采样点转成连续的三次 Bézier 段（Catmull-Rom → Bézier 转换）。
    /// 相邻段在连接点共享切线（c2 与下一段 c1 关于连接点对称），保证 C1 连续；
    /// 供 Canvas addCurve / UIBezierPath addCurve 曲线渲染，不产生折线段。
    static func bezierSegments(_ points: [CGPoint]) -> [(control1: CGPoint, control2: CGPoint, end: CGPoint)] {
        guard points.count >= 2 else { return [] }
        var segments: [(CGPoint, CGPoint, CGPoint)] = []
        segments.reserveCapacity(points.count - 1)
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            let m1 = CGPoint(x: (p2.x - p0.x) / 2, y: (p2.y - p0.y) / 2)
            let m2 = CGPoint(x: (p3.x - p1.x) / 2, y: (p3.y - p1.y) / 2)
            segments.append((
                CGPoint(x: p1.x + m1.x / 3, y: p1.y + m1.y / 3),
                CGPoint(x: p2.x - m2.x / 3, y: p2.y - m2.y / 3),
                p2
            ))
        }
        return segments
    }

    /// Hermite 三次插值：p1→p2 段，两端切线分别为 m1/m2。
    static func hermitePoint(p1: CGPoint, p2: CGPoint, m1: CGPoint, m2: CGPoint, t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return CGPoint(
            x: h00 * p1.x + h10 * m1.x + h01 * p2.x + h11 * m2.x,
            y: h00 * p1.y + h10 * m1.y + h01 * p2.y + h11 * m2.y
        )
    }

    /// 轨迹动画总时长（秒）：独立动画时间轴，与关键点之间的视频时间间隔无关。
    /// 无论关键点在视频中相隔 1 秒还是 5 秒，整条轨迹都以相同节奏绘制。
    static let paceTotalDuration: TimeInterval = 7.0

    /// 下降段平均延伸速度相对上升段的比值（下降段明显更慢）。
    static let paceDescentSpeedRatio = 0.6

    /// 播放进度 → 轨迹采样截取长度（独立动画时间轴 + 归一化弧长）。
    /// 几何路径始终由全部关键点生成；动画进度以「整条曲线的弧长」为基准：
    /// - 动画时间轴与视频时间轴分离：总时长固定为 paceTotalDuration，
    ///   视频时间只用于确定「何时开始绘制」和关键点对应的画面帧，
    ///   不参与任何速度计算（关键点视频间隔不影响轨迹运动快慢）；
    /// - 上升段（起点→最高点）：幂函数前快后缓；
    /// - 下降段（最高点→落点）：顶点处时间占比由 paceDescentSpeedRatio 反推
    ///   （平均速度 = 上升段的 60%），Hermite 映射保证顶点速度连续，
    ///   接近落点时进一步减速（幅度由 paceDeceleration 控制）。
    /// 最高点由关键点几何（y 最小）识别，与视频时间无关。
    /// 返回 nil 表示绘制完整曲线；返回 0 表示尚未开始、不绘制；
    /// 否则返回**分数采样位置**（如 42.7），调用方在采样点之间插值，
    /// 保证轨迹末端每帧连续移动（消除慢速阶段的顿挫感）。
    static func drawSampleCount(
        geometry: TrajectoryGeometry,
        keyPoints: [TracePoint],
        clipTime: TimeInterval,
        paceDeceleration: Double,
        videoDuration: TimeInterval = 0
    ) -> Double? {
        guard let totalLength = geometry.cumulativeLengths.last, totalLength > 0 else { return nil }
        guard let tStart = keyPoints.first?.time else { return nil }
        // 独立动画时间轴：总时长固定；仅当视频余量不足时压缩，保证视频结束前画完
        var total = paceTotalDuration
        if videoDuration > 0 {
            total = max(min(total, videoDuration - tStart), 1.0)
        }
        let s = min(max((clipTime - tStart) / total, 0), 1)
        if s <= 0 { return 0 }
        if s >= 1 { return nil }

        // 识别最高点：y 最小的中间关键点（仅作缓动分界，不影响几何）
        var apexIndex: Int?
        if keyPoints.count >= 3 {
            var minY = Double.greatestFiniteMagnitude
            for i in 1..<(keyPoints.count - 1) where keyPoints[i].y < minY {
                minY = keyPoints[i].y
                apexIndex = i
            }
        }

        var q = s
        if let apex = apexIndex {
            let qApex = geometry.keyCumulativeLengths[apex] / totalLength
            if qApex > 0.02, qApex < 0.98 {
                // 由下降段/上升段平均速度比反推顶点处的绘制时间占比
                let ratio = paceDescentSpeedRatio
                var sApex = ratio * qApex / (1 - qApex + ratio * qApex)
                sApex = min(max(sApex, 0.05), 0.95)
                q = easedArcFraction(
                    s: s,
                    apexArcFraction: qApex,
                    apexTimeFraction: sApex,
                    deceleration: paceDeceleration
                )
            }
        }

        let targetLength = q * totalLength
        let lengths = geometry.cumulativeLengths
        var index = 0
        while index < lengths.count, lengths[index] < targetLength {
            index += 1
        }
        guard index > 0, index < lengths.count else {
            return Double(min(index, lengths.count))
        }
        // 在两个采样点之间按弧长分数插值 → 分数采样位置
        let previousLength = lengths[index - 1]
        let nextLength = lengths[index]
        let fraction = nextLength > previousLength
            ? (targetLength - previousLength) / (nextLength - previousLength)
            : 0
        return Double(index - 1) + fraction
    }

    /// 分段缓动映射：归一化视频时间 s ∈ [0,1] → 归一化弧长 q ∈ [0,1]。
    /// 上升段 q = qA·(s/sA)^α（α=0.7，前快后缓）；
    /// 下降段用 Hermite 过渡，顶点处斜率与上升段连续，落点处斜率按减速参数降低。
    static func easedArcFraction(
        s: Double,
        apexArcFraction qApex: Double,
        apexTimeFraction sApex: Double,
        deceleration: Double
    ) -> Double {
        let alpha = 0.7
        if s <= sApex {
            guard sApex > 0 else { return 0 }
            return qApex * pow(s / sApex, alpha)
        }
        let u = (s - sApex) / (1 - sApex)
        // 顶点处斜率连续：上升段末端斜率 = 下降段起始斜率
        let d0 = qApex * alpha / sApex * (1 - sApex) / (1 - qApex)
        // 落点处斜率：按减速参数降低（0 = 匀速下降，1 = 明显减速收尾）
        let decel = min(max(deceleration, 0), 1)
        let d1 = d0 * (1 - 0.85 * decel)
        let f = scalarHermite(p0: 0, p1: 1, m0: min(d0, 3), m1: d1, t: u)
        return qApex + (1 - qApex) * f
    }

    /// 标量 Hermite 插值：f(0)=p0，f(1)=p1，两端斜率 m0/m1
    static func scalarHermite(p0: Double, p1: Double, m0: Double, m1: Double, t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1
    }
}
