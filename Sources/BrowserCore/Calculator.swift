import Foundation

/// The little calculator of the address bar: type "12*3+4" or "(2+3)^2 / 5" and the answer is proposed (and copied with Return).
/// Numbers may use a comma or a dot; `×` and `÷` work like `*` and `/`; `%` after a number divides it by 100.
public enum Calculator {
    /// nil when the text is not a calculation (no operator, an unknown character, a division by zero, an absurd size…).
    public static func evaluate(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: ",", with: ".")
        guard cleaned.count >= 3, cleaned.count <= 120, cleaned.contains(where: \.isNumber) else { return nil }
        // Only a calculation: without an operator, "2024" or "3.14" is just a number or a search.
        guard cleaned.dropFirst().contains(where: { "+-*/^%".contains($0) }) else { return nil }
        guard cleaned.allSatisfy({ "0123456789.+-*/^%()".contains($0) }) else { return nil }
        var parser = Parser(Array(cleaned))
        guard let value = parser.parseExpression(), parser.atEnd, value.isFinite, abs(value) < 1e15 else { return nil }
        return value
    }

    /// "42", "3,14159265", "0,3" (at most 10 significant digits, French decimal comma, no trailing zeros).
    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.10g", value)
        if text.contains("e") { text = String(format: "%.10f", value) }
        if text.contains(".") { while text.hasSuffix("0") { text.removeLast() }; if text.hasSuffix(".") { text.removeLast() } }
        return text.replacingOccurrences(of: ".", with: ",")
    }

    // expression := term (('+'|'-') term)* ; term := power (('*'|'/') power)* ; power := unary ('^' power)? ; unary := '-' unary | primary '%'?
    private struct Parser {
        let chars: [Character]
        var index = 0
        init(_ chars: [Character]) { self.chars = chars }
        var atEnd: Bool { index >= chars.count }
        private func peek() -> Character? { index < chars.count ? chars[index] : nil }
        private mutating func take(_ c: Character) -> Bool { if peek() == c { index += 1; return true }; return false }

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                index += 1
                guard let rhs = parseTerm() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func parseTerm() -> Double? {
            guard var value = parsePower() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                index += 1
                guard let rhs = parsePower() else { return nil }
                if op == "/" { guard rhs != 0 else { return nil }; value /= rhs } else { value *= rhs }
            }
            return value
        }

        private mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            if take("^") {
                guard let exponent = parsePower(), abs(exponent) <= 1000 else { return nil }
                let result = pow(base, exponent)
                return result.isFinite ? result : nil
            }
            return base
        }

        private mutating func parseUnary() -> Double? {
            if take("-") { return parseUnary().map { -$0 } }
            if take("+") { return parseUnary() }
            guard var value = parsePrimary() else { return nil }
            while take("%") { value /= 100 }
            return value
        }

        private mutating func parsePrimary() -> Double? {
            if take("(") {
                guard let value = parseExpression(), take(")") else { return nil }
                return value
            }
            let start = index
            var dots = 0
            while let c = peek(), c.isNumber || c == "." { if c == "." { dots += 1 }; index += 1 }
            guard index > start, dots <= 1, let value = Double(String(chars[start..<index])) else { return nil }
            return value
        }
    }
}
