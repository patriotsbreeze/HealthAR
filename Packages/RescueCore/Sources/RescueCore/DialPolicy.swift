import Foundation

/// The only place that may build a dial URL. Demo builds pass an allowlist holding at most a
/// teammate's mock dispatcher number, and emergency numbers are refused even if listed.
public enum DialPolicy {
    private static let emergencyNumbers: Set<String> = ["911", "112", "999", "000", "110", "119", "118", "933"]

    public static func dialURL(for number: String, allowlist: Set<String>) -> URL? {
        let digits = normalize(number)
        guard !digits.isEmpty, !isEmergencyNumber(digits) else { return nil }
        guard allowlist.map(normalize).contains(digits) else { return nil }
        return URL(string: "tel:\(digits)")
    }

    public static func isEmergencyNumber(_ number: String) -> Bool {
        let digits = normalize(number)
        if emergencyNumbers.contains(digits) { return true }
        // Catches a leading country code such as 1911.
        return digits.count <= 6 && emergencyNumbers.contains { digits.hasSuffix($0) }
    }

    private static func normalize(_ number: String) -> String {
        number.filter(\.isNumber)
    }
}
