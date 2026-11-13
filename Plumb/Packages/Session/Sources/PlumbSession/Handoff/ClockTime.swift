import Foundation

/// The time of day a moment falls on in one time zone, on a 24-hour clock.
struct ClockTime: Equatable {
    var hour: Int
    var minute: Int
    var second: Int

    init(_ date: Date, in timeZone: TimeZone) {
        // Read with a fixed calendar rather than a formatter, so the device's 12 or 24 hour
        // setting and language cannot change what is written.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        hour = parts.hour ?? 0
        minute = parts.minute ?? 0
        second = parts.second ?? 0
    }

    /// For example "14:02" or "09:05".
    var hoursAndMinutes: String {
        "\(Self.twoDigits(hour)):\(Self.twoDigits(minute))"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
