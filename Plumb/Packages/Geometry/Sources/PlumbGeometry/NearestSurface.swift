import Foundation

extension DepthPatch {
    /// The numbers that decide what counts as a surface inside a depth patch.
    public struct SurfaceConfig: Sendable, Equatable {
        /// Depths nearer than this are sensor junk. Default 0.15 m.
        public var minDepthM: Double
        /// Depths farther than this are beyond useful LiDAR range. Default 5 m.
        public var maxDepthM: Double
        /// Width of one histogram bin. Default 0.01 m.
        public var binWidthM: Double
        /// Empty stretch of depth a single surface may still span, which lets a knuckle and a
        /// wrist count as one thing. Default 0.03 m.
        public var bridgeGapM: Double
        /// Share of the usable samples a group needs before it counts as a surface and not as
        /// speckle. Default 0.15.
        public var minShare: Double
        /// Fewest samples a group may hold, whatever its share. Default 6.
        public var minGroupSamples: Int

        /// Builds a config; every argument defaults to the documented value.
        public init(minDepthM: Double = 0.15, maxDepthM: Double = 5, binWidthM: Double = 0.01,
                    bridgeGapM: Double = 0.03, minShare: Double = 0.15, minGroupSamples: Int = 6) {
            self.minDepthM = minDepthM
            self.maxDepthM = maxDepthM
            self.binWidthM = binWidthM
            self.bridgeGapM = bridgeGapM
            self.minShare = minShare
            self.minGroupSamples = minGroupSamples
        }
    }

    /// What a depth patch says about the nearest real surface in it.
    public struct Reading: Sendable, Equatable {
        /// Median planar depth of the surface, in metres.
        public var depthM: Double
        /// Share of all the patch's samples that belong to the surface, 0...1.
        public var validFraction: Double
        /// Interquartile range of the surface's depths, in metres. Small for one flat thing.
        public var spreadM: Double

        /// Builds a reading from its three numbers.
        public init(depthM: Double, validFraction: Double, spreadM: Double) {
            self.depthM = depthM
            self.validFraction = validFraction
            self.spreadM = spreadM
        }
    }

    /// Reads the nearest surface in the patch: the hands, when the patch holds hands in front of
    /// something farther away. Nil when no group of depths is big enough to trust.
    ///
    /// Usable samples are finite, inside the config's depth range and at or above `minConfidence`.
    /// They are counted into bins; neighbouring occupied bins, with small gaps bridged, form
    /// groups; the nearest group holding a large enough share of the usable samples is the surface.
    public func nearestSurface(minConfidence: UInt8 = 1, config: SurfaceConfig = .init()) -> Reading? {
        guard config.binWidthM > 0, config.maxDepthM > config.minDepthM, !depthsM.isEmpty else { return nil }
        let usable = usableDepths(minConfidence: minConfidence, config: config)
        let needed = max(config.minGroupSamples, Int((config.minShare * Double(usable.count)).rounded(.up)))
        guard let bins = nearestGroup(in: usable, holdingAtLeast: needed, config: config) else { return nil }
        let group = usable.filter { bins.contains(config.bin(of: $0)) }.sorted()
        guard let median = Stats.quantile(ofSorted: group, 0.5),
              let lowerQuartile = Stats.quantile(ofSorted: group, 0.25),
              let upperQuartile = Stats.quantile(ofSorted: group, 0.75) else { return nil }
        return Reading(depthM: median,
                       validFraction: Double(group.count) / Double(depthsM.count),
                       spreadM: upperQuartile - lowerQuartile)
    }

    private func usableDepths(minConfidence: UInt8, config: SurfaceConfig) -> [Double] {
        var usable: [Double] = []
        usable.reserveCapacity(depthsM.count)
        for index in depthsM.indices {
            let level = index < confidence.count ? confidence[index] : Self.highConfidence
            let metres = Double(depthsM[index])
            guard level >= minConfidence, metres.isFinite,
                  metres >= config.minDepthM, metres <= config.maxDepthM else { continue }
            usable.append(metres)
        }
        return usable
    }

    /// Counts the depths into bins and walks the bins from the camera outward. Returns the bins of
    /// the first run of occupied bins, small gaps bridged, that holds at least `needed` samples.
    private func nearestGroup(in usable: [Double], holdingAtLeast needed: Int,
                              config: SurfaceConfig) -> ClosedRange<Int>? {
        var counts = [Int](repeating: 0, count: config.bin(of: config.maxDepthM) + 1)
        for depth in usable {
            counts[config.bin(of: depth)] += 1
        }
        let bridgeBins = Int((config.bridgeGapM / config.binWidthM).rounded())
        var first: Int?
        var last = 0
        var held = 0
        for bin in counts.indices where counts[bin] > 0 {
            // An empty stretch too wide to bridge closes the group before it.
            if let begun = first, bin - last - 1 > bridgeBins {
                if held >= needed { return begun...last }
                first = nil
                held = 0
            }
            first = first ?? bin
            last = bin
            held += counts[bin]
        }
        guard let begun = first, held >= needed else { return nil }
        return begun...last
    }

    /// The level given to samples of a patch that carries no confidence map.
    private static let highConfidence: UInt8 = 2
}

extension DepthPatch.SurfaceConfig {
    /// Which histogram bin a depth inside the sane range falls in; bin 0 starts at `minDepthM`.
    fileprivate func bin(of depthM: Double) -> Int {
        Int(((depthM - minDepthM) / binWidthM).rounded(.down))
    }
}
