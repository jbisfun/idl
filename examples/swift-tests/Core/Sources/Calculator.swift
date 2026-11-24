import Foundation

/// Host-portable logic (Foundation only): built into iOS apps by `idl build`
/// and tested on Linux by `idl test`.
public struct Calculator {
    public private(set) var memory: Double = 0

    public init() {}

    public func evaluate(_ lhs: Double, _ op: Character, _ rhs: Double) -> Double? {
        switch op {
        case "+": return lhs + rhs
        case "-": return lhs - rhs
        case "*", "×": return lhs * rhs
        case "/", "÷": return rhs == 0 ? nil : lhs / rhs
        default: return nil
        }
    }

    public mutating func store(_ value: Double) {
        memory = value
    }

    /// Formats without a trailing ".0" for whole numbers.
    public static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}
