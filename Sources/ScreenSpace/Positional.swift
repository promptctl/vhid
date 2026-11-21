public extension Double {
    /// This number in positional notation: the shortest digits that read back as it, with
    /// no exponent of ten at either end, no `.0` on a whole number and no sign on a zero.
    /// `1e-05` is `0.00001`, `1e+20` is `100000000000000000000`, `-0.0` is `0`.
    ///
    /// [LAW:one-source-of-truth] The one way a coordinate is written: a point, a box, and
    /// every refusal that names a number. Swift's own spelling already has the shortest
    /// digits, so they are taken from it and only their place is moved; a number that is not
    /// finite has no digits to place and is written as Swift writes it, `nan` or `inf`.
    var positional: String {
        guard isFinite else { return description }
        guard self != 0 else { return "0" }
        let shortest = magnitude.description.split(separator: "e")
        let exponent = shortest.count == 2 ? Int(shortest[1])! : 0
        let mantissa = shortest[0].split(separator: ".", omittingEmptySubsequences: false)
        let whole = mantissa[0], fraction = mantissa.count == 2 ? mantissa[1] : ""
        // The digits with no zero at either end, and where the point falls among them.
        var digits = Substring(whole + fraction)
        var point = whole.count + exponent
        while digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.last == "0" { digits.removeLast() }
        let written: String = if point <= 0 {
            "0." + String(repeating: "0", count: -point) + digits
        } else if point >= digits.count {
            String(digits) + String(repeating: "0", count: point - digits.count)
        } else {
            "\(digits.prefix(point)).\(digits.dropFirst(point))"
        }
        return (self < 0 ? "-" : "") + written
    }
}
