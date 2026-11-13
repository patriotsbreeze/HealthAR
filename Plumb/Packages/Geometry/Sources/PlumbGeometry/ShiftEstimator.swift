import Foundation

/// Finds how far the picture inside a luma patch has slid along world-up since a key frame.
///
/// Each patch is reduced to profiles of row means, one per vertical strip. The middle of the key
/// frame's profiles is slid over the new ones a whole row at a time; the slide with the best
/// normalised cross-correlation wins and a parabola through it and its two neighbours gives the
/// fraction of a row.
public struct ShiftEstimator: Sendable {
    /// The numbers that shape the search.
    public struct Config: Sendable, Equatable {
        /// Farthest slide searched in either direction, as a share of the rows. Default 0.4.
        public var maxShiftFraction: Double
        /// Share of the rows, taken from the middle of the key frame, that is matched. The hands
        /// sit in the middle; whatever shows above and below them may not move with them.
        /// 1 matches the whole profile. Default 0.5.
        public var templateFraction: Double
        /// Vertical strips the patch is cut into, each with its own row profile. More strips tell
        /// unrelated pictures apart better; fewer forgive more sideways motion. 1 is a single
        /// profile of whole-row means. Default 4.
        public var bands: Int
        /// Share of the matched rows that must still lie inside the patch for a slide to be
        /// scored. Default 0.5.
        public var minOverlapFraction: Double
        /// Brightness variation, as a standard deviation in grey levels, below which a stretch
        /// of rows is too flat to match and scores zero. Default 0.5.
        public var minContrast: Double

        /// Builds a config; every argument defaults to the documented value.
        public init(maxShiftFraction: Double = 0.4, templateFraction: Double = 0.5, bands: Int = 4,
                    minOverlapFraction: Double = 0.5, minContrast: Double = 0.5) {
            self.maxShiftFraction = maxShiftFraction
            self.templateFraction = templateFraction
            self.bands = bands
            self.minOverlapFraction = minOverlapFraction
            self.minContrast = minContrast
        }
    }

    private struct KeyFrame: Sendable {
        var profiles: RowProfiles
        var pitchPx: Double
    }

    private let config: Config
    private var key: KeyFrame?

    /// Makes an estimator with no key frame yet.
    public init(config: Config = .init()) {
        self.config = config
    }

    /// Forgets the key frame, so the next patch becomes the new one.
    public mutating func rekey() {
        key = nil
    }

    /// How far the picture has slid since the key frame, in image pixels (positive means the
    /// content moved up in the world), and how well it matched, 0 no match to 1 identical.
    /// The first patch after `init` or `rekey` becomes the key frame and returns (0, 1).
    /// A patch whose size or row spacing differs from the key frame's matches nothing: (0, 0).
    /// Nil when the patch is malformed.
    public mutating func estimate(_ patch: LumaPatch) -> (upPx: Double, correlation: Double)? {
        guard patch.pitchPx > 0, let profiles = patch.rowProfiles(bands: config.bands) else { return nil }
        guard let key else {
            self.key = KeyFrame(profiles: profiles, pitchPx: patch.pitchPx)
            return (0, 1)
        }
        // Rows of another grid are not the key frame's rows, so sliding one over the other means nothing.
        guard key.pitchPx == patch.pitchPx, key.profiles.bands == profiles.bands,
              key.profiles.rows == profiles.rows else { return (0, 0) }
        let match = bestSlide(of: key.profiles, over: profiles)
        // Rows count downward in the world, so sliding to a larger row index is moving down.
        return (-match.rowsDown * patch.pitchPx, min(max(match.correlation, 0), 1))
    }

    // MARK: - Search

    private func bestSlide(of key: RowProfiles, over current: RowProfiles) -> (rowsDown: Double, correlation: Double) {
        let template = templateRows(of: current.rows)
        let reach = Int(Double(current.rows) * config.maxShiftFraction)
        // Raw buffers for the same reason as in `LumaPatch.rowProfiles`: every frame, tight loop.
        let scores: [Double?] = key.means.withUnsafeBufferPointer { keyMeans in
            current.means.withUnsafeBufferPointer { currentMeans in
                (-reach...reach).map { slide in
                    score(keyMeans, against: currentMeans, bands: key.bands, rows: key.rows,
                          template: template, slide: slide)
                }
            }
        }
        // With no slide scoring above zero nothing matched, and no slide is better than another.
        guard let best = scores.indices.max(by: { (scores[$0] ?? -1) < (scores[$1] ?? -1) }),
              let peak = scores[best], peak > 0 else { return (0, 0) }
        let slide = Double(best - reach)
        guard best > 0, best < scores.count - 1,
              let before = scores[best - 1], let after = scores[best + 1] else { return (slide, peak) }
        // Fit a parabola through the peak and its neighbours; its top is the sub-row answer.
        let curvature = before - 2 * peak + after
        guard curvature < 0 else { return (slide, peak) }
        let offset = min(max(0.5 * (before - after) / curvature, -0.5), 0.5)
        return (slide + offset, peak - 0.25 * (before - after) * offset)
    }

    /// The middle rows of the key frame that get matched.
    private func templateRows(of rows: Int) -> Range<Int> {
        let length = min(rows, max(2, Int((Double(rows) * config.templateFraction).rounded())))
        let start = (rows - length) / 2
        return start..<(start + length)
    }

    /// Normalised cross-correlation between the key frame's template rows and the rows `slide`
    /// further down in the current patch. Each strip has its own mean removed, then all strips are
    /// pooled. Nil when too little of the template still lies inside the patch.
    private func score(_ key: UnsafeBufferPointer<Double>, against current: UnsafeBufferPointer<Double>,
                       bands: Int, rows: Int, template: Range<Int>, slide: Int) -> Double? {
        let lower = max(template.lowerBound, -slide)
        let upper = min(template.upperBound, rows - slide)
        let overlap = upper - lower
        guard overlap >= 2, Double(overlap) >= config.minOverlapFraction * Double(template.count) else { return nil }
        let count = Double(overlap)
        var keyEnergy = 0.0, currentEnergy = 0.0, product = 0.0
        for band in 0..<bands {
            let strip = band * rows
            var keySum = 0.0, currentSum = 0.0, keySquares = 0.0, currentSquares = 0.0, cross = 0.0
            var row = strip + lower
            let end = strip + upper
            while row < end {
                let a = key[row]
                let b = current[row + slide]
                keySum += a
                currentSum += b
                keySquares += a * a
                currentSquares += b * b
                cross += a * b
                row += 1
            }
            // Sums of squares about each strip's own mean over the rows compared.
            keyEnergy += keySquares - keySum * keySum / count
            currentEnergy += currentSquares - currentSum * currentSum / count
            product += cross - keySum * currentSum / count
        }
        // Dividing by the energy of a flat stretch would turn sensor noise into a confident match.
        let flat = config.minContrast * config.minContrast * count * Double(bands)
        guard keyEnergy > flat, currentEnergy > flat else { return 0 }
        return product / (keyEnergy * currentEnergy).squareRoot()
    }
}
