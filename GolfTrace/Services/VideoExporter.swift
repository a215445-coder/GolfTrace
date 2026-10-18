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

        NSLog("[GolfTrace导出] 开始渲染视频")
        try await render(shot: shot, to: outputURL)
        NSLog("[GolfTrace导出] 渲染完成，保存到相册")
        try await saveVideoToPhotos(url: outputURL)
        NSLog("[GolfTrace导出] 已保存到相册")
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// 把带轨迹覆盖层的图片保存到相册
    func exportImageToPhotos(shot: ShotRecord) async throws {
        guard let image = UIImage(contentsOfFile: shot.mediaURL.path) else {
            throw VideoExporterError(errorDescription: "无法读取图片")
        }
        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let geometry = VideoGeometry.trajectoryGeometry(
            keyPoints: shot.trace.sortedPoints.map(\.location),
            bendLeft: shot.trace.bendLeft,
            bendRight: shot.trace.bendRight
        )
        let rendered = renderer.image { ctx in
            image.draw(in: CGRect(origin: .zero, size: size))
            drawTrace(shot: shot, geometry: geometry, clipTime: nil, size: size)
        }
        try await saveImageToPhotos(rendered)
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

        let durationTime = try? await asset.load(.duration)
        // 几何全程只计算一次（归一化坐标），逐帧仅做截取与像素映射
        let geometry = VideoGeometry.trajectoryGeometry(
            keyPoints: shot.trace.sortedPoints.map(\.location),
            bendLeft: shot.trace.bendLeft,
            bendRight: shot.trace.bendRight
        )
        // CIContext 全程复用：逐帧创建 GPU 上下文会拖慢导出并在真机上耗尽资源
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        try await transcode(
            reader: reader,
            writer: writer,
            videoOutput: readerOutput,
            videoInput: writerInput,
            adaptor: adaptor,
            shot: shot,
            geometry: geometry,
            ciContext: ciContext,
            renderSize: renderSize,
            orientation: VideoGeometry.orientation(from: videoTrack.preferredTransform),
            videoDuration: durationTime?.seconds ?? 0
        )
    }

    private func transcode(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        shot: ShotRecord,
        geometry: TrajectoryGeometry,
        ciContext: CIContext,
        renderSize: CGSize,
        orientation: CGImagePropertyOrientation,
        videoDuration: TimeInterval
    ) async throws {
        guard reader.startReading(), writer.startWriting() else {
            NSLog("[GolfTrace导出] 无法开始导出: reader=\(reader.error?.localizedDescription ?? "nil") writer=\(writer.error?.localizedDescription ?? "nil")")
            throw VideoExporterError(errorDescription: "无法开始导出")
        }
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "app.golftrace.export")
            queue.async {
                do {
                    var frameIndex = 0
                    while let sample = videoOutput.copyNextSampleBuffer() {
                        var waitLoops = 0
                        while !videoInput.isReadyForMoreMediaData {
                            Thread.sleep(forTimeInterval: 0.01)
                            waitLoops += 1
                            if waitLoops > 500 {
                                NSLog("[GolfTrace导出] 等待写入器就绪超时 status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "nil")")
                                throw VideoExporterError(errorDescription: "导出写入器无响应")
                            }
                        }
                        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        let frame = try self.drawnFrame(
                            from: pixelBuffer,
                            orientation: orientation,
                            size: renderSize,
                            shot: shot,
                            geometry: geometry,
                            ciContext: ciContext,
                            time: time.seconds,
                            videoDuration: videoDuration
                        )
                        if !adaptor.append(frame, withPresentationTime: time) {
                            NSLog("[GolfTrace导出] append 失败 status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "nil")")
                            throw VideoExporterError(errorDescription: "写入画面失败")
                        }
                        frameIndex += 1
                        if frameIndex % 50 == 0 {
                            NSLog("[GolfTrace导出] 已处理 \(frameIndex) 帧")
                        }
                    }
                    NSLog("[GolfTrace导出] 帧循环结束，共 \(frameIndex) 帧 readerStatus=\(reader.status.rawValue)")
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
        geometry: TrajectoryGeometry,
        ciContext: CIContext,
        time: TimeInterval,
        videoDuration: TimeInterval
    ) throws -> CVPixelBuffer {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw VideoExporterError(errorDescription: "无法绘制视频帧")
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
            drawTrace(shot: shot, geometry: geometry, clipTime: time, videoDuration: videoDuration, size: size)
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
        ciContext.render(overlay, to: output)
        return output
    }

    /// 在给定尺寸的画布上绘制轨迹（样式来自 shot.trace），供视频逐帧和图片导出共用。
    /// geometry 为预计算的归一化轨迹几何（导出全程只算一次）；逐帧仅做截取与像素映射。
    /// clipTime 为 nil 时绘制完整曲线（图片导出）；否则按归一化弧长沿曲线裁切（视频逐帧）。
    private func drawTrace(
        shot: ShotRecord,
        geometry: TrajectoryGeometry,
        clipTime: TimeInterval?,
        videoDuration: TimeInterval = 0,
        size: CGSize
    ) {
        let points = shot.trace.sortedPoints
        guard points.count >= 2 else { return }
        var pathPoints: [CGPoint] = []
        var drawAll = true
        if let clipTime {
            if let count = VideoGeometry.drawSampleCount(
                geometry: geometry,
                keyPoints: points,
                clipTime: clipTime,
                paceDeceleration: shot.trace.paceDeceleration,
                videoDuration: videoDuration
            ) {
                guard count > 0 else { return }
                drawAll = false
                let samples = geometry.samples
                let whole = min(Int(count.rounded(.down)), samples.count)
                pathPoints = samples.prefix(whole).map {
                    CGPoint(x: $0.x * size.width, y: $0.y * size.height)
                }
                let fraction = count - Double(whole)
                if fraction > 0.0001 {
                    if whole == 0, samples.count >= 2 {
                        // 轨迹起点：在第一个采样点与其后一点之间插值
                        pathPoints.append(CGPoint(
                            x: (samples[0].x + (samples[1].x - samples[0].x) * fraction) * size.width,
                            y: (samples[0].y + (samples[1].y - samples[0].y) * fraction) * size.height
                        ))
                    } else if whole > 0, whole < samples.count {
                        let a = samples[whole - 1]
                        let b = samples[whole]
                        pathPoints.append(CGPoint(
                            x: (a.x + (b.x - a.x) * fraction) * size.width,
                            y: (a.y + (b.y - a.y) * fraction) * size.height
                        ))
                    }
                }
            }
        }
        if drawAll {
            pathPoints = geometry.samples.map {
                CGPoint(x: $0.x * size.width, y: $0.y * size.height)
            }
        }
        // 轨迹尚未延伸出足够长度时不绘制（避免空路径崩溃）
        guard pathPoints.count >= 2 else { return }
        let path = UIBezierPath()
        path.move(to: pathPoints[0])
        // 连续三次 Bézier 曲线渲染：相邻段共享切线，整条轨迹无折线
        for segment in VideoGeometry.bezierSegments(pathPoints) {
            path.addCurve(to: segment.end, controlPoint1: segment.control1, controlPoint2: segment.control2)
        }
        let baseLineWidth = max(shot.trace.lineWidth, Double(size.width) / 180)
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        // 光晕层：更宽、低透明度，与主线同步延伸
        path.lineWidth = baseLineWidth * 2.6
        UIColor(
            red: shot.trace.colorRed,
            green: shot.trace.colorGreen,
            blue: shot.trace.colorBlue,
            alpha: shot.trace.opacity * 0.22
        ).setStroke()
        path.stroke()
        // 主线：清晰锐利
        path.lineWidth = baseLineWidth
        UIColor(
            red: shot.trace.colorRed,
            green: shot.trace.colorGreen,
            blue: shot.trace.colorBlue,
            alpha: shot.trace.opacity
        ).setStroke()
        path.stroke()

        // 球当前位置：柔光晕 + 清晰圆点，随曲线末端移动
        if let last = pathPoints.last {
            let dotRadius = max(6, size.width / 240)
            let halo = UIBezierPath(
                ovalIn: CGRect(
                    x: last.x - dotRadius * 2,
                    y: last.y - dotRadius * 2,
                    width: dotRadius * 4,
                    height: dotRadius * 4
                )
            )
            UIColor(
                red: shot.trace.colorRed,
                green: shot.trace.colorGreen,
                blue: shot.trace.colorBlue,
                alpha: shot.trace.opacity * 0.25
            ).setFill()
            halo.fill()
            let dot = UIBezierPath(
                ovalIn: CGRect(
                    x: last.x - dotRadius,
                    y: last.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )
            )
            UIColor(red: 1, green: 0.27, blue: 0, alpha: 1).setFill()
            dot.fill()
        }
    }

    private func saveVideoToPhotos(url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        NSLog("[GolfTrace导出] 相册权限: \(status.rawValue)")
        guard status == .authorized || status == .limited else {
            throw VideoExporterError(errorDescription: "没有相册写入权限")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        } catch {
            NSLog("[GolfTrace导出] 保存视频失败: \(error.localizedDescription)")
            throw error
        }
    }

    private func saveImageToPhotos(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        NSLog("[GolfTrace导出] 相册权限: \(status.rawValue)")
        guard status == .authorized || status == .limited else {
            throw VideoExporterError(errorDescription: "没有相册写入权限")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        } catch {
            NSLog("[GolfTrace导出] 保存图片失败: \(error.localizedDescription)")
            throw error
        }
    }
}
