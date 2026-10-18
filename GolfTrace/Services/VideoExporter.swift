import AVFoundation
import Photos
import UIKit

struct VideoExporterError: LocalizedError {
    var errorDescription: String?
}

final class VideoExporter: @unchecked Sendable {
    func exportToPhotos(shot: ShotRecord) async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GolfTrace-\(shot.id.uuidString).mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        try await render(shot: shot, to: outputURL)
        try await saveToPhotos(url: outputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func render(shot: ShotRecord, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: shot.videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw VideoExporterError(errorDescription: "视频里没有画面轨道")
        }

        let displaySize = VideoGeometry.displaySize(for: videoTrack)
        let renderSize = CGSize(
            width: max(2, floor(displaySize.width / 2) * 2),
            height: max(2, floor(displaySize.height / 2) * 2)
        )

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: renderSize.width,
                AVVideoHeightKey: renderSize.height
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = .identity

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: renderSize.width,
                kCVPixelBufferHeightKey as String: renderSize.height
            ]
        )
        writer.add(writerInput)

        try await transcode(
            reader: reader,
            writer: writer,
            videoOutput: readerOutput,
            videoInput: writerInput,
            adaptor: adaptor,
            shot: shot,
            renderSize: renderSize,
            orientation: VideoGeometry.orientation(from: videoTrack.preferredTransform)
        )
    }

    private func transcode(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        shot: ShotRecord,
        renderSize: CGSize,
        orientation: CGImagePropertyOrientation
    ) async throws {
        guard reader.startReading(), writer.startWriting() else {
            throw VideoExporterError(errorDescription: "无法开始导出")
        }
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "app.golftrace.export")
            queue.async {
                do {
                    while let sample = videoOutput.copyNextSampleBuffer() {
                        while !videoInput.isReadyForMoreMediaData {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        let frame = try self.drawnFrame(
                            from: pixelBuffer,
                            orientation: orientation,
                            size: renderSize,
                            shot: shot,
                            time: time.seconds
                        )
                        if !adaptor.append(frame, withPresentationTime: time) {
                            throw VideoExporterError(errorDescription: "写入画面失败")
                        }
                    }
                    videoInput.markAsFinished()

                    writer.finishWriting {
                        if let error = writer.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                } catch {
                    writer.cancelWriting()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func drawnFrame(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        size: CGSize,
        shot: ShotRecord,
        time: TimeInterval
    ) throws -> CVPixelBuffer {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw VideoExporterError(errorDescription: "无法绘制视频帧")
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
            let points = shot.trace.points(upTo: time)
            guard points.count >= 2 else { return }

            let path = UIBezierPath()
            for (index, point) in points.enumerated() {
                let mapped = CGPoint(x: point.x * size.width, y: point.y * size.height)
                if index == 0 {
                    path.move(to: mapped)
                } else {
                    path.addLine(to: mapped)
                }
            }
            path.lineWidth = max(4, size.width / 180)
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            UIColor(red: 1, green: 0.84, blue: 0, alpha: 0.95).setStroke()
            path.stroke()

            if let last = points.last {
                let center = CGPoint(x: last.x * size.width, y: last.y * size.height)
                let dot = UIBezierPath(
                    ovalIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
                )
                UIColor(red: 1, green: 0.27, blue: 0, alpha: 1).setFill()
                dot.fill()
            }
        }

        var output: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess, let output else {
            throw VideoExporterError(errorDescription: "无法创建导出帧")
        }

        guard let overlay = CIImage(image: image) else {
            throw VideoExporterError(errorDescription: "无法写入导出帧")
        }
        context.render(overlay, to: output)
        return output
    }

    private func saveToPhotos(url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw VideoExporterError(errorDescription: "没有相册写入权限")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
