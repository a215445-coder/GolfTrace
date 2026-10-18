import AVFoundation
import Foundation
import Vision

struct TrajectoryDetectorError: LocalizedError {
    var errorDescription: String?
}

final class TrajectoryDetector: @unchecked Sendable {
    func detect(in url: URL) async throws -> ShotTrace {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw TrajectoryDetectorError(errorDescription: "视频里没有画面轨道")
        }

        let display = VideoGeometry.displaySize(for: track)
        let orientation = VideoGeometry.orientation(from: track.preferredTransform)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw TrajectoryDetectorError(errorDescription: "无法读取视频帧")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw TrajectoryDetectorError(errorDescription: reader.error?.localizedDescription ?? "无法开始读视频")
        }

        let request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 10)
        request.objectMinimumNormalizedRadius = 0.002
        request.objectMaximumNormalizedRadius = 0.1

        let handler = VNSequenceRequestHandler()
        var series: [UUID: [TracePoint]] = [:]
        var confidence: [UUID: Float] = [:]

        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds

            try handler.perform([request], on: pixelBuffer, orientation: orientation)
            let observations = request.results ?? []
            for observation in observations {
                confidence[observation.uuid] = observation.confidence
                guard let last = observation.detectedPoints.last else { continue }
                let point = TracePoint(
                    time: time,
                    x: Double(last.x),
                    y: 1 - Double(last.y),
                    source: .automatic
                )
                var points = series[observation.uuid, default: []]
                if let previous = points.last {
                    let dx = previous.x - point.x
                    let dy = previous.y - point.y
                    if (dx * dx + dy * dy) < 0.00000025 { continue }
                }
                points.append(point)
                series[observation.uuid] = points
            }
        }

        if reader.status == .failed {
            throw TrajectoryDetectorError(errorDescription: reader.error?.localizedDescription ?? "读视频失败")
        }

        let best = pickBestTrajectory(series, confidence: confidence)
        return ShotTrace(
            points: best.points,
            confidence: best.confidence,
            videoWidth: display.width,
            videoHeight: display.height
        )
    }

    private func pickBestTrajectory(
        _ series: [UUID: [TracePoint]],
        confidence: [UUID: Float]
    ) -> (points: [TracePoint], confidence: Float) {
        var scored: [(points: [TracePoint], confidence: Float, score: Double)] = []

        for (id, points) in series {
            let ordered = points.sorted { $0.time < $1.time }
            guard ordered.count >= 5 else { continue }
            let duration = ordered.last!.time - ordered.first!.time
            guard duration >= 0.12 else { continue }

            let dx = ordered.last!.x - ordered.first!.x
            let dy = ordered.last!.y - ordered.first!.y
            let displacement = sqrt(dx * dx + dy * dy)
            guard displacement >= 0.06 else { continue }

            let conf = Double(confidence[id] ?? 0)
            let startsLow = ordered.prefix(3).map(\.y).average
            let heightBonus = startsLow > 0.35 ? 1.15 : 0.85
            let score = conf * duration * displacement * 8 * heightBonus
            scored.append((ordered, Float(conf), score))
        }

        return scored.max { $0.score < $1.score }.map { ($0.points, $0.confidence) }
            ?? ([], 0)
    }
}

private extension Sequence where Element == Double {
    var average: Double {
        var total = 0.0
        var count = 0
        for value in self {
            total += value
            count += 1
        }
        return count == 0 ? 0 : total / Double(count)
    }
}
