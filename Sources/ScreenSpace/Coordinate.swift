/// How a coordinate is written, wherever one is: a point, a box, and every refusal that
/// names a number. [LAW:one-source-of-truth]
public enum Coordinate {
    /// The shortest digits that read back as `value`, written out positionally: `1e20` as
    /// `100000000000000000000`, `1e-05` as `0.00001`, since a box printed for an agent to
    /// pass on is read by more than Swift. No `.0` on a whole number, no sign on zero - the
    /// `-0` an origin computes to is the same place. `nan`, `inf` and `-inf` as Swift spells
    /// them, so a refusal can name what it refused.
    public static func spelled(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        guard value != 0 else { return "0" }
        return (value < 0 ? "-" : "") + positional(value.magnitude).trimmedFraction
    }

    /// Swift's shortest round-trip digits for a positive finite `magnitude`, with the
    /// exponent it uses past 2^53 and under 1e-4 written out as places.
    private static func positional(_ magnitude: Double) -> String {
        let shortest = "\(magnitude)"
        let parts = shortest.split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return shortest }
        let mantissa = parts[0]
        let point = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
        let digits = Array(mantissa.filter { $0 != "." })
        let at = point + exponent
        if at <= 0 { return "0." + String(repeating: "0", count: -at) + String(digits) }
        if at >= digits.count { return String(digits) + String(repeating: "0", count: at - digits.count) }
        return String(digits[..<at]) + "." + String(digits[at...])
    }
}

private extension String {
    /// Without trailing zeros after a point, and without the point when nothing follows it.
    var trimmedFraction: String {
        guard contains(".") else { return self }
        let trimmed = String(reversed().drop { $0 == "0" }.reversed())
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }
}
