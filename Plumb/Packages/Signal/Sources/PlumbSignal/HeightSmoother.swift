import Foundation

/// Light exponential smoothing whose strength follows the real time between readings,
/// so uneven spacing and dropped samples do not distort it.
struct HeightSmoother: Sendable {
    private let timeConstantS: Double
    private var value: Double?
    private var lastT: TimeInterval = 0

    init(timeConstantS: Double) {
        self.timeConstantS = timeConstantS
    }

    /// Takes the next reading and returns the smoothed height at that moment.
    mutating func smooth(_ reading: CleanReading) -> Double {
        defer { lastT = reading.t }
        guard let current = value, timeConstantS > 0 else {
            value = reading.heightMM
            return reading.heightMM
        }
        let weight = 1 - exp(-(reading.t - lastT) / timeConstantS)
        let next = current + weight * (reading.heightMM - current)
        value = next
        return next
    }
}
