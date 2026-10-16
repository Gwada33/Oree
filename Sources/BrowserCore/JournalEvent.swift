import Foundation

/// Une valeur d'un événement du journal : un nombre, un texte tiré d'une liste fermée (ou une empreinte), un oui/non. Jamais du texte libre.
public enum JournalValue: Codable, Equatable, Sendable {
    case int(Int), double(Double), string(String), bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .int(let v): try c.encode(v); case .double(let v): try c.encode(v); case .string(let v): try c.encode(v); case .bool(let v): try c.encode(v) }
    }
    public var int: Int? { if case .int(let v) = self { v } else if case .double(let v) = self { Int(v) } else { nil } }
    public var double: Double? { if case .double(let v) = self { v } else if case .int(let v) = self { Double(v) } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
}

/// Une ligne du journal : un instant (secondes depuis 1970, à la milliseconde), un nom, des champs.
public struct JournalEvent: Codable, Equatable, Sendable {
    public var t: Double
    public var e: String
    public var d: [String: JournalValue]
    public init(t: Double, e: String, d: [String: JournalValue] = [:]) { self.t = t; self.e = e; self.d = d }
}
