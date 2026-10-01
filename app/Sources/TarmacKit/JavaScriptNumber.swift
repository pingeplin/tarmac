extension Double {
    /// JavaScript's `String(number)` (ECMAScript Number::toString): the shortest
    /// round-trip digits, written out in full from 10^-6 up to 10^21 and in
    /// exponent form beyond. Swift's `description` has the same digits but switches
    /// layout earlier and pads exponents to two digits, so only its digits are used.
    var javaScriptString: String {
        if isNaN { return "NaN" }
        if self == 0 { return "0" }
        if self < 0 { return "-" + (-self).javaScriptString }
        if isInfinite { return "Infinity" }

        // self = 0.<digits> × 10^point
        let (digits, point) = shortestDigits
        let count = digits.count
        if count <= point, point <= 21 { return digits + String(repeating: "0", count: point - count) }
        if 0 < point, point <= 21 { return String(digits.prefix(point)) + "." + String(digits.dropFirst(point)) }
        if -6 < point, point <= 0 { return "0." + String(repeating: "0", count: -point) + digits }
        let exponent = point - 1
        let tail = "e" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
        return count == 1 ? digits + tail : String(digits.prefix(1)) + "." + String(digits.dropFirst()) + tail
    }

    /// The shortest round-trip digits of a positive finite value, without leading or
    /// trailing zeros, and the decimal point position they sit at.
    private var shortestDigits: (digits: String, point: Int) {
        let text = "\(self)"
        let parts = text.split(separator: "e", maxSplits: 1)
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let integerPart = mantissa[0]
        let fractionPart = mantissa.count > 1 ? mantissa[1] : ""
        var digits = Substring(integerPart + fractionPart)
        var point = integerPart.count + (parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        while digits.count > 1, digits.first == "0" {
            digits = digits.dropFirst()
            point -= 1
        }
        while digits.count > 1, digits.last == "0" { digits = digits.dropLast() }
        return (String(digits), point)
    }
}
