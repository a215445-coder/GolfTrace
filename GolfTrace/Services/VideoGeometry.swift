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

    /// 侧弯最大水平偏移 = 视频画面宽度的比例（全局侧弯包络的峰值幅度）
    static let lateralBowMaxRatio = 0.4

    /// 根据全部关键点生成平滑轨迹采样点：基础曲线 + 弦参考系的高度缩放与侧向倾斜。
    /// 第一遍：所有关键点作为一条完整路径，用 Fritsch–Carlson 风格切线 + Hermite 插值。
    /// 第二遍（高度缩放 + 侧向偏移）：以离弦高度（相对「起点→终点弦」的垂直距离）为强度——
    /// 高度 = 离弦高度按 (1 + bendHeight) 缩放，位移沿屏幕竖直方向；
    /// 侧弯 = 位移沿屏幕水平方向、与离弦高度成正比（b = bendRight − bendLeft 为有符号强度），
    /// 顶点偏移最大、两端为零，像高尔夫 draw/fade 一样整条弧线向一侧平滑倾斜。
    /// 两者坐标轴正交、互不干扰；变换对高度场线性：轨迹从头到尾平滑、绝不交叉。
    /// 坐标系无关：输入输出同一坐标系，调用方用归一化或像素坐标均可。
    static func trajectoryGeometry(
        keyPoints: [CGPoint],
        bendLeft: Double,
        bendRight: Double,
        bendHeight: Double = 0
    ) -> TrajectoryGeometry {
        guard keyPoints.count >= 2 else {
            return TrajectoryGeometry(samples: keyPoints, cumulativeLengths: [], keyCumulativeLengths: [])
        }
        let n = keyPoints.count
        // 弯曲强度：左负右正，单一有符号值。
        // 0.8 次幂映射：低中档位更明显、档位差异清晰；最大档位为 1（对应最大侧弯幅度）。
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

        // 第二步：逐段 Hermite 采样并记录累计弧长（侧弯/高度在第三步统一施加）
        let steps = trajectoryStepsPerSegment
        var samples: [CGPoint] = []
        var cumulativeLengths: [Double] = []
        var keyCumulativeLengths: [Double] = []
        samples.reserveCapacity((n - 1) * steps + 1)
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
                if let previous = samples.last {
                    totalLength += hypot(point.x - previous.x, point.y - previous.y)
                }
                samples.append(point)
                cumulativeLengths.append(totalLength)
            }
        }
        let lastPoint = keyPoints[n - 1]
        if let previous = samples.last {
            totalLength += hypot(lastPoint.x - previous.x, lastPoint.y - previous.y)
        }
        samples.append(lastPoint)
        cumulativeLengths.append(totalLength)
        keyCumulativeLengths.append(totalLength)

        // 第三步（高度缩放 + 侧向偏移）：以离弦高度为强度做纯轴向变换——
        // 高度 = 离弦高度按 (1 + bendHeight) 缩放，位移沿屏幕竖直方向；
        // 侧弯 = 位移沿屏幕水平方向、与离弦高度成正比（顶点偏移最大、两端为零）。
        // 高度与左右坐标轴正交、互不干扰；变换对高度场线性：绝不交叉、从头到尾平滑。
        if bendStrength != 0 || bendHeight != 0 {
            if let frame = bendFrame(samples: samples), frame.apexHeight > 0.0001 {
                // 侧弯幅度相对画面宽度固定：轨迹在画面里再小也能拉到足够大的弯；
                // 离弦高度不足 0.15 时按 0.15 折算，避免扁平轨迹剪切过猛
                let lateralRatio = (bendStrength * lateralBowMaxRatio) / max(frame.apexHeight, 0.15)
                let firstX = samples[0].x
                let firstY = samples[0].y
                for i in samples.indices {
                    let h = Double(samples[i].x - firstX) * frame.nx + Double(samples[i].y - firstY) * frame.ny
                    // 纯轴向：左右只动 x、上下只动 y，互不干扰
                    samples[i].y -= CGFloat(h * bendHeight)
                    samples[i].x += CGFloat(h * lateralRatio)
                }
            } else if let total = cumulativeLengths.last, total > 0 {
                // 退化兜底（轨迹近似直线、离弦高度为零）：按弧长 sin²(π·u) 包络弓起，
                // 让只有起点终点的直线也能被弯曲手柄塑形成弧线
                for i in samples.indices {
                    let u = cumulativeLengths[i] / total
                    let envelope = sin(.pi * u)
                    let envelope2 = envelope * envelope
                    if bendStrength != 0 {
                        samples[i].x += CGFloat(bendStrength * lateralBowMaxRatio) * CGFloat(envelope2)
                    }
                    if bendHeight != 0 {
                        samples[i].y -= CGFloat(bendHeight) * CGFloat(envelope2)
                    }
                }
            }
        }

        return TrajectoryGeometry(
            samples: samples,
            cumulativeLengths: cumulativeLengths,
            keyCumulativeLengths: keyCumulativeLengths
        )
    }

    /// 弯曲参考系：以「起点→终点弦」为基准的坐标框架。
    /// 返回弦单位方向 (dx, dy)、屏幕上方单位法向 (nx, ny)、顶点采样下标与顶点离弦高度。
    /// 起点终点重合时退化为水平弦（dx=1, ny=-1），保证弯曲始终可用。
    static func bendFrame(samples: [CGPoint]) -> (dx: Double, dy: Double, nx: Double, ny: Double, apexIndex: Int, apexHeight: Double)? {
        guard samples.count >= 2 else { return nil }
        let first = samples[0]
        let last = samples[samples.count - 1]
        let chordX = Double(last.x - first.x)
        let chordY = Double(last.y - first.y)
        let chordLength = hypot(chordX, chordY)
        let dx: Double
        let dy: Double
        if chordLength > 0.0001 {
            dx = chordX / chordLength
            dy = chordY / chordLength
        } else {
            dx = 1
            dy = 0
        }
        var nx = -dy
        var ny = dx
        if ny > 0 {
            nx = -nx
            ny = -ny
        }
        var apexIndex = 0
        var apexHeight = -Double.greatestFiniteMagnitude
        for i in samples.indices {
            let h = Double(samples[i].x - first.x) * nx + Double(samples[i].y - first.y) * ny
            if h > apexHeight {
                apexHeight = h
                apexIndex = i
            }
        }
        return (dx, dy, nx, ny, apexIndex, apexHeight)
    }

    /// 弯曲编辑手柄下标：顶点 = 离弦高度最大的采样点；
    /// 侧弯手柄 = 下降侧（顶点之后）离弦高度约为顶点一半的采样点。
    /// 轨迹近似直线时退化为弧长 1/2 与 3/4 处，保证直线也能被塑形。
    static func bendHandleIndices(geometry: TrajectoryGeometry, base: TrajectoryGeometry) -> (apex: Int, lateral: Int)? {
        guard base.samples.count >= 2, geometry.samples.count == base.samples.count,
              let frame = bendFrame(samples: base.samples) else { return nil }
        let samples = base.samples
        let first = samples[0]
        if frame.apexHeight <= 0.0001 {
            let mid = samples.count / 2
            return (mid, min(mid + samples.count / 4, samples.count - 1))
        }
        let apex = frame.apexIndex
        let half = frame.apexHeight / 2
        var lateral = apex
        for i in apex..<samples.count {
            let h = Double(samples[i].x - first.x) * frame.nx + Double(samples[i].y - first.y) * frame.ny
            if h <= half {
                lateral = i
                break
            }
        }
        return (apex, lateral)
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

    /// 上升段绝对时长（秒）：快速跟球，幂函数前快后缓
    static let paceRiseDuration: TimeInterval = 0.75
    /// 下降段绝对时长（秒）：匀速、较缓
    static let paceDescentDuration: TimeInterval = 9.0
    /// 无顶点（两点轨迹）时的固定总时长
    static let paceFlatDuration: TimeInterval = 7.0
    /// 下降段起始平滑过渡占比（从上升末端速率过渡到匀速速率）
    static let paceDescentBlendFraction = 0.25

    /// 上升段缓动指数（幂函数前快后缓）：越小上升越急促、越跟球。
    /// 同时用于解出顶点时间占比，保证上升段末端斜率与匀速下降段斜率在顶点处连续
    static let paceRiseAlpha = 0.18

    /// 播放进度 → 轨迹采样截取长度（独立动画时间轴 + 归一化弧长）。
    /// 几何路径始终由全部关键点生成；动画进度以「整条曲线的弧长」为基准：
    /// - 动画时间轴与视频时间轴分离：有顶点时总时长 = 上升段固定时长 + 下降段时长，
    ///   视频时间只用于确定「何时开始绘制」；关键点视频间隔不影响轨迹运动快慢；
    /// - 上升段（起点→最高点）：固定时长 paceRiseDuration，幂函数前快后缓、快速跟球；
    /// - 下降段（最高点→落点）：先平滑过渡到匀速速率，之后全程匀速、无减速收尾，
    ///   时长较长（paceDescentDuration）、缓缓落下；
    /// - 无顶点的两点轨迹：固定总时长匀速绘制；
    /// - 视频余量不足时压缩总时长，保证视频结束前画完（上升段真实时长保持不变）。
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

        // 识别最高点：y 最小的中间关键点（仅作缓动分界，不影响几何）
        var apexIndex: Int?
        if keyPoints.count >= 3 {
            var minY = Double.greatestFiniteMagnitude
            for i in 1..<(keyPoints.count - 1) where keyPoints[i].y < minY {
                minY = keyPoints[i].y
                apexIndex = i
            }
        }

        // 独立动画时间轴：有顶点时上升段固定时长（快速跟球）、下降段匀速且时长较长（较缓）；
        // 无顶点时固定总时长；视频余量不足时压缩，保证视频结束前画完
        var total = apexIndex != nil ? paceRiseDuration + paceDescentDuration : paceFlatDuration
        if videoDuration > 0 {
            total = max(min(total, videoDuration - tStart), 1.0)
        }
        let s = min(max((clipTime - tStart) / total, 0), 1)
        if s <= 0 { return 0 }
        if s >= 1 { return nil }

        var q = s
        if let apex = apexIndex {
            let qApex = geometry.keyCumulativeLengths[apex] / totalLength
            if qApex > 0.02, qApex < 0.98 {
                // 顶点时间占比 = 上升段固定时长 / 总时长（视频压缩时上升段真实时长不变）
                let sApex = min(max(paceRiseDuration / total, 0.03), 0.9)
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
    /// 上升段 q = qA·(s/sA)^α（前快后缓）；
    /// 下降段：先按 smoothstep 从上升末端速率平滑过渡到匀速速率（顶点处速度连续），
    /// 之后全程匀速、速率恒定、无减速收尾。
    /// deceleration 参数保留兼容（匀速下降不再使用）。
    static func easedArcFraction(
        s: Double,
        apexArcFraction qApex: Double,
        apexTimeFraction sApex: Double,
        deceleration: Double
    ) -> Double {
        if s <= sApex {
            guard sApex > 0 else { return 0 }
            return qApex * pow(s / sApex, paceRiseAlpha)
        }
        let u = (s - sApex) / (1 - sApex)
        // 上升段末端速率（弧长/归一化时间）与下降段平均速率
        let riseEndSpeed = qApex * paceRiseAlpha / sApex
        let meanSpeed = (1 - qApex) / (1 - sApex)
        // 匀速阶段速率：由「过渡段均值 + 匀速段均值 = 下降段平均速率」解出
        let b = paceDescentBlendFraction
        let targetSpeed = max((meanSpeed - b * riseEndSpeed / 2) / (1 - b / 2), 0.02)
        if u <= b {
            // 过渡段：速率从 riseEndSpeed 平滑过渡到 targetSpeed，积分可解析
            let t = u / b
            let integral = riseEndSpeed * u + (targetSpeed - riseEndSpeed) * b * (t * t * t - t * t * t * t / 2)
            return qApex + (1 - sApex) * integral
        }
        // 匀速段：恒定速率 targetSpeed
        let blendArc = riseEndSpeed * b + (targetSpeed - riseEndSpeed) * b / 2
        return qApex + (1 - sApex) * (blendArc + targetSpeed * (u - b))
    }
}
