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

    init(id: UUID = UUID(), time: TimeInterval, x: Double, y: Double, source: Source) {
        self.id = id
        self.time = time
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.source = source
    }

    var location: CGPoint { CGPoint(x: x, y: y) }
}

struct ShotTrace: Codable, Hashable {
    var points: [TracePoint]
    var confidence: Float
    var videoWidth: Double
    var videoHeight: Double

    var hasAutomaticPoints: Bool {
        points.contains { $0.source == .automatic }
    }

    var sortedPoints: [TracePoint] {
        points.sorted { $0.time < $1.time }
    }

    func points(upTo time: TimeInterval) -> [TracePoint] {
        sortedPoints.filter { $0.time <= time + 0.02 }
    }
}

struct ShotRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var createdAt: Date
    var videoFileName: String
    var trace: ShotTrace

    var displayTitle: String {
        createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}
