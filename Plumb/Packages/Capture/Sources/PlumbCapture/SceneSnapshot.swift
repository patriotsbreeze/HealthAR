import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import PlumbGeometry
import UniformTypeIdentifiers

/// One frame copied on the capture queue for a scene snapshot, before its picture is turned into
/// colour. `Sendable` unchecked because `image` is this package's own copy (see `ImageCopier`),
/// written before it is handed over and only read after.
struct SnapshotCopy: @unchecked Sendable {
    /// Copy of the captured image: bi-planar YCbCr, in the sensor's native landscape orientation.
    let image: CVPixelBuffer
    /// Copy of the same frame's depth map.
    let depth: DepthMap
    /// The same frame's camera.
    let camera: FrameCamera
    /// The frame's own capture time, on the system's uptime clock.
    let timestamp: TimeInterval
}

/// A still of the scene: one frame's picture, depth map and camera, copied out of ARKit so it can
/// be kept for as long as needed and read from any thread.
///
/// Image points are normalised image coordinates: 0...1 across the camera's landscape picture,
/// origin at its top-left, the same space as `CaptureStatus` rectangles and `CameraView` taps.
/// Pixel lengths are in the full-resolution captured image, the pixels the intrinsics are in.
public struct SceneSnapshot: Sendable {
    /// The picture in 8-bit RGBA, as the sensor sees it: the landscape image, top row first. With
    /// people filled in when `peopleHidden` is set.
    public let image: CGImage
    /// What was filled in, on a snapshot from `hidingPeople()`. Nil on a snapshot straight from the
    /// camera, whose picture may show people and must stay on the phone.
    public let peopleHidden: PeopleHidden?
    /// The camera's lens values for the picture.
    public let intrinsics: Intrinsics
    /// Where the camera stood, in the session's gravity-aligned world.
    public let pose: CameraPose
    /// The frame's own capture time, on the system's uptime clock (`ProcessInfo.systemUptime`).
    public let timestamp: TimeInterval
    /// Copy of the frame's depth map.
    let depth: DepthMap
    /// Lowest LiDAR confidence a depth grid cell reads (0 low, 1 medium, 2 high).
    let minConfidence: UInt8

    /// Turns a copied frame's YCbCr picture into colour, following the colour matrix the buffer
    /// carries. Depth grid cells will need at least `minConfidence`. Nil when the picture cannot
    /// be converted.
    init?(_ copy: SnapshotCopy, minConfidence: UInt8) {
        let picture = CIImage(cvPixelBuffer: copy.image)
        guard let image = Self.renderer.createCGImage(picture, from: picture.extent, format: .RGBA8,
                                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            return nil
        }
        self.image = image
        peopleHidden = nil
        intrinsics = copy.camera.intrinsics
        pose = copy.camera.pose
        timestamp = copy.timestamp
        depth = copy.depth
        self.minConfidence = minConfidence
    }

    /// `snapshot` with its picture replaced by `picture`, a copy with people filled in, as
    /// `peopleHidden` reports.
    init(_ snapshot: SceneSnapshot, picture: CGImage, peopleHidden: PeopleHidden) {
        image = picture
        self.peopleHidden = peopleHidden
        intrinsics = snapshot.intrinsics
        pose = snapshot.pose
        timestamp = snapshot.timestamp
        depth = snapshot.depth
        minConfidence = snapshot.minConfidence
    }

    /// Size of the captured image in pixels, as the intrinsics give it.
    public var imageSize: CGSize { CGSize(width: intrinsics.width, height: intrinsics.height) }

    /// Where the camera was, in metres, in the session's gravity-aligned world.
    public var cameraPosition: SIMD3<Float> { SIMD3<Float>(pose.position) }

    /// The world point seen at a normalised image point when the surface there is `depthM` metres
    /// away along the lens axis (planar depth, as `DepthGrid` gives it). Metres in the session's
    /// gravity-aligned world, the space `CameraView.Coordinator` places entities in.
    public func worldPoint(at point: CGPoint, depthM: Double) -> SIMD3<Float> {
        let pixel = pixel(at: point)
        return SIMD3<Float>(Projection.unproject(u: pixel.u, v: pixel.v, depthM: depthM,
                                                 intrinsics: intrinsics, pose: pose))
    }

    /// A JPEG of part of the picture: `region` (normalised image coordinates) is cut out, then
    /// scaled down, never up, until its longer side is at most `maxLongSide` pixels. `quality` runs
    /// from 0 (smallest) to 1 (best). Nil when the region holds no whole pixel of the picture,
    /// `maxLongSide` is below 1, or encoding fails.
    ///
    /// Only a JPEG of a snapshot from `hidingPeople()` (one whose `peopleHidden` is set) may leave
    /// the phone. This does not check, so the same cut can be made of any snapshot for use here.
    public func jpeg(region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), maxLongSide: Int = 1024,
                     quality: Double = 0.7) -> Data? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let wanted = CGRect(x: region.minX * width, y: region.minY * height,
                            width: region.width * width, height: region.height * height)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        // A null or not-a-number rectangle fails these too.
        guard maxLongSide >= 1, wanted.width >= 1, wanted.height >= 1,
              let cut = image.cropping(to: wanted),
              let shrunk = Self.redrawn(cut, longSideAtMost: maxLongSide) else { return nil }
        return Self.jpegData(shrunk, quality: quality)
    }

    /// Image pixel under a normalised image point, read the way a tap is read when seeding.
    func pixel(at point: CGPoint) -> (u: Double, v: Double) {
        (Double(point.x) * Double(intrinsics.width), Double(point.y) * Double(intrinsics.height))
    }

    /// Shared, because a context is costly to make and safe to use from any thread.
    private static let renderer = CIContext(options: [.cacheIntermediates: false])

    /// The picture drawn opaque into 8-bit RGB, which JPEG holds without dropping anything, scaled
    /// so its longer side is at most `longSide` pixels. Nil when no bitmap could be made.
    private static func redrawn(_ picture: CGImage, longSideAtMost longSide: Int) -> CGImage? {
        let scale = min(1, Double(longSide) / Double(max(picture.width, picture.height)))
        let width = max(Int((Double(picture.width) * scale).rounded()), 1)
        let height = max(Int((Double(picture.height) * scale).rounded()), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: picture.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func jpegData(_ picture: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)] as CFDictionary
        CGImageDestinationAddImage(destination, picture, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
