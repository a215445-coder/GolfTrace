import CoreGraphics
import Foundation

struct TracePoint: Identifiable, Hashable, Codable {
    enum Source: String, Codable {
        case automatic
        case manual
    }

    var id: UUID
    var time: TimeInterval
    var x: Double
    var y: Double
    var source: Source
    /// 插入顺序，用于时间相同时（如图片模式所有点 time=0）保持稳定排序
    var sequence: Int

    init(id: UUID = UUID(), time: TimeInterval, x: Double, y: Double, source: Source, sequence: Int = 0) {
        self.id = id
        self.time = time
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.source = source
        self.sequence = sequence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        time = try container.decode(TimeInterval.self, forKey: .time)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .manual
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
    }

    var location: CGPoint { CGPoint(x: x, y: y) }
}

enum MediaType: String, Codable {
    case video
    case image
}

struct ShotTrace: Codable, Hashable {
    var points: [TracePoint]
    var confidence: Float
    var videoWidth: Double
    var videoHeight: Double

    // 轨迹样式
    var lineWidth: Double
    var opacity: Double
    var bendLeft: Double
    var bendRight: Double
    /// 高度弓起幅度（归一化，正 = 轨迹向上隆起，两端不动、弧长中点最大）
    var bendHeight: Double
    var colorRed: Double
    var colorGreen: Double
    var colorBlue: Double
    /// 下降段减速幅度（0 = 匀速下降，1 = 明显减速收尾），只影响动画节奏不改几何
    var paceDeceleration: Double
    /// 是否在轨迹旁显示距离数字
    var showDistance: Bool
    /// 用户设定的目标距离（码），播放时数字从 0 逐渐涨到该值
    var targetDistance: Double

    static let defaultColor = (red: 1.0, green: 0.84, blue: 0.0)
    /// 默认轨迹线宽（较细，约为旧默认值 4 的 70%）
    static let defaultLineWidth = 2.8

    init(
        points: [TracePoint],
        confidence: Float = 0,
        videoWidth: Double,
        videoHeight: Double,
        lineWidth: Double = ShotTrace.defaultLineWidth,
        opacity: Double = 1,
        bendLeft: Double = 0,
        bendRight: Double = 0,
        bendHeight: Double = 0,
        colorRed: Double = ShotTrace.defaultColor.red,
        colorGreen: Double = ShotTrace.defaultColor.green,
        colorBlue: Double = ShotTrace.defaultColor.blue,
        paceDeceleration: Double = 0.6,
        showDistance: Bool = false,
        targetDistance: Double = 250
    ) {
        self.points = points
        self.confidence = confidence
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.lineWidth = lineWidth
        self.opacity = opacity
        self.bendLeft = bendLeft
        self.bendRight = bendRight
        self.bendHeight = bendHeight
        self.colorRed = colorRed
        self.colorGreen = colorGreen
        self.colorBlue = colorBlue
        self.paceDeceleration = paceDeceleration
        self.showDistance = showDistance
        self.targetDistance = targetDistance
    }

    // 旧版本 JSON 没有样式字段，用默认值兜底保证旧记录可读
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decodeIfPresent([TracePoint].self, forKey: .points) ?? []
        confidence = try container.decodeIfPresent(Float.self, forKey: .confidence) ?? 0
        videoWidth = try container.decodeIfPresent(Double.self, forKey: .videoWidth) ?? 0
        videoHeight = try container.decodeIfPresent(Double.self, forKey: .videoHeight) ?? 0
        lineWidth = try container.decodeIfPresent(Double.self, forKey: .lineWidth) ?? ShotTrace.defaultLineWidth
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        bendLeft = try container.decodeIfPresent(Double.self, forKey: .bendLeft) ?? 0
        bendRight = try container.decodeIfPresent(Double.self, forKey: .bendRight) ?? 0
        bendHeight = try container.decodeIfPresent(Double.self, forKey: .bendHeight) ?? 0
        colorRed = try container.decodeIfPresent(Double.self, forKey: .colorRed) ?? ShotTrace.defaultColor.red
        colorGreen = try container.decodeIfPresent(Double.self, forKey: .colorGreen) ?? ShotTrace.defaultColor.green
        colorBlue = try container.decodeIfPresent(Double.self, forKey: .colorBlue) ?? ShotTrace.defaultColor.blue
        paceDeceleration = try container.decodeIfPresent(Double.self, forKey: .paceDeceleration) ?? 0.6
        showDistance = try container.decodeIfPresent(Bool.self, forKey: .showDistance) ?? false
        targetDistance = try container.decodeIfPresent(Double.self, forKey: .targetDistance) ?? 250
    }

    var sortedPoints: [TracePoint] {
        points.sorted { ($0.time, $0.sequence) < ($1.time, $1.sequence) }
    }

    func points(upTo time: TimeInterval) -> [TracePoint] {
        sortedPoints.filter { $0.time <= time + 0.02 }
    }
}

struct ShotRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var createdAt: Date
    var videoFileName: String
    var imageFileName: String?
    var mediaType: MediaType
    var trace: ShotTrace

    init(
        id: UUID,
        createdAt: Date,
        videoFileName: String,
        imageFileName: String? = nil,
        mediaType: MediaType,
        trace: ShotTrace
    ) {
        self.id = id
        self.createdAt = createdAt
        self.videoFileName = videoFileName
        self.imageFileName = imageFileName
        self.mediaType = mediaType
        self.trace = trace
    }

    // 旧记录没有 mediaType/imageFileName，默认按视频处理
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        videoFileName = try container.decodeIfPresent(String.self, forKey: .videoFileName) ?? ""
        imageFileName = try container.decodeIfPresent(String?.self, forKey: .imageFileName) ?? nil
        mediaType = try container.decodeIfPresent(MediaType.self, forKey: .mediaType) ?? .video
        trace = try container.decode(ShotTrace.self, forKey: .trace)
    }

    var displayTitle: String {
        createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}
