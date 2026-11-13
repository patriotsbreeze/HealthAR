import Foundation

/// Where recordings go and what they say about the phone that made them.
enum TraceNaming {
    /// A new file in the app's Documents folder named after the moment, to the millisecond, so two
    /// recordings never land on the same name.
    static func newFileURL(at date: Date) throws -> URL {
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return folder.appendingPathComponent("plumb-trace-\(formatter.string(from: date))Z.jsonl")
    }

    /// The hardware model, such as "iPhone16,2". In the Simulator, the Mac's architecture.
    static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
