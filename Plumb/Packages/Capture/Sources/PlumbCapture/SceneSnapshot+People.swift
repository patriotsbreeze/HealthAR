import CoreGraphics
import Foundation

/// What `SceneSnapshot.hidingPeople()` filled in, so the app can say plainly what it hid.
public struct PeopleHidden: Sendable, Equatable {
    /// Share of the picture's pixels filled with flat ground colour, 0...1: everyone the person
    /// mask found, grown a few pixels, and every face box with its margin.
    public let filledFraction: Double
    /// Faces found. Each face's box is filled whether or not the person mask covered it.
    public let faceCount: Int

    /// What was hidden, as one plain sentence for the session log, for example
    /// "People hidden before sending: 12% of the picture, 1 face."
    public var sentence: String {
        guard filledFraction > 0 else { return "People hidden before sending: no one found in the picture." }
        let percent = Int((filledFraction * 100).rounded())
        // A sliver is still someone, so it is never rounded down to nothing.
        let share = percent == 0 ? "under 1%" : "\(percent)%"
        let faces = faceCount == 0 ? "no faces" : faceCount == 1 ? "1 face" : "\(faceCount) faces"
        return "People hidden before sending: \(share) of the picture, \(faces)."
    }
}

extension SceneSnapshot {
    /// A copy of this snapshot whose picture has every person Vision finds in it filled with the
    /// app's flat ground colour, #0B0D11, and whose `peopleHidden` says how much was filled. This is
    /// the only snapshot that may leave the phone. A flat fill rather than a blur, because a blur can
    /// still show who someone is.
    ///
    /// Person segmentation at its most careful quality finds the people; the mask is grown a few
    /// pixels so no edge of a person shows, and every face Vision finds is filled with a margin
    /// as well, in case the mask missed it. Depth, camera and time are kept as they are.
    ///
    /// Nil when Vision fails or the copy cannot be made: the caller then sends nothing. The picture
    /// as it was is never given back from here. Takes a fraction of a second, off the caller's
    /// thread. Call from anywhere.
    public func hidingPeople() async -> SceneSnapshot? {
        await hidingPeople(lookingWith: PeopleSighting.look(at:))
    }

    /// `hidingPeople()` with Vision replaced by `look`, which gives nil on failure.
    func hidingPeople(lookingWith look: (CGImage) async -> PeopleSighting?) async -> SceneSnapshot? {
        guard let sighting = await look(image),
              // A face found but placed nowhere cannot be hidden, so nothing is given.
              sighting.faces.allSatisfy(\.hasFiniteEdges),
              var mask = PeopleMask(coverage: sighting.coverage, coverageWidth: sighting.coverageWidth,
                                    coverageHeight: sighting.coverageHeight, threshold: PeopleHiding.coverageThreshold,
                                    width: image.width, height: image.height) else { return nil }
        // A coarse mask's edge can be a whole mask cell out, so it grows by one of its cells as well.
        let cellPx = max((image.width + sighting.coverageWidth - 1) / sighting.coverageWidth,
                         (image.height + sighting.coverageHeight - 1) / sighting.coverageHeight)
        mask.grow(by: PeopleHiding.growPx + cellPx)
        let size = CGSize(width: image.width, height: image.height)
        for face in sighting.faces {
            if let box = PeopleMask.faceBox(face, margin: PeopleHiding.faceMargin, within: size) { mask.hide(box) }
        }
        guard let painted = Self.painting(image, hiding: mask) else { return nil }
        return SceneSnapshot(self, picture: painted,
                             peopleHidden: PeopleHidden(filledFraction: mask.hiddenFraction,
                                                        faceCount: sighting.faces.count))
    }

    /// `picture` redrawn into 8-bit sRGB with every pixel `mask` hides set to the ground colour.
    /// Every other pixel keeps its exact value. Nil when the mask is not the picture's size or no
    /// bitmap could be made.
    static func painting(_ picture: CGImage, hiding mask: PeopleMask) -> CGImage? {
        guard mask.width == picture.width, mask.height == picture.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: picture.width, height: picture.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return nil }
        context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let ground = PeopleHiding.ground
        for row in 0..<mask.height {
            let rowStart = bytes + row * context.bytesPerRow
            for column in 0..<mask.width where mask.hidden[row * mask.width + column] {
                let pixel = rowStart + column * 4
                pixel[0] = ground.red
                pixel[1] = ground.green
                pixel[2] = ground.blue
                pixel[3] = 255
            }
        }
        return context.makeImage()
    }
}

/// How people are hidden. Fixed in code: nothing at run time can loosen it.
enum PeopleHiding {
    /// A pixel is a person's when the mask gives it a quarter or more; the mask's soft edge is
    /// grown over anyway, and hiding a little floor costs nothing.
    static let coverageThreshold: UInt8 = 64
    /// Pixels the person mask grows by on every side, on top of one mask cell.
    static let growPx = 4
    /// Each face box grows by this share of its width on the left and right and of its height
    /// above and below.
    static let faceMargin = 0.3
    /// The app's ground colour, #0B0D11, in sRGB.
    static let ground: (red: UInt8, green: UInt8, blue: UInt8) = (0x0B, 0x0D, 0x11)
}
