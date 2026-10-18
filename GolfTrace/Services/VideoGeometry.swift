import AVFoundation
import CoreGraphics
import ImageIO

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
}
