import Foundation

/// A single comparable attribute value — what a segment filter compares against.
///
/// Mirrors `AttrValue` in `backend/packages/core/src/types.ts`, which is
/// `string | number | boolean | null` and nothing else. The narrowness is the
/// point: every filter, segment rule and personalisation token reads this bag,
/// and a nested object or array would have no defined comparison semantics on
/// the server. Swift has no untyped JSON value, so the union becomes an enum.
///
/// The narrowness is now load-bearing in a second way. One-to-many data
/// (`challenges`, `badges`) does NOT widen this enum — it arrives as a separate
/// flat `CollectionItem` type whose fields are `AttrValue`s. Adding a `.list` or
/// `.object` case here would turn every exhaustive `switch` on `AttrValue`, in
/// this SDK and in integrators' code, into a compile error — a breaking change
/// for a feature most integrations will not use. Collections are deferred to
/// the next release and are additive when they land; do not widen this enum to
/// bring them forward.
///
/// `null` is a real case rather than an absent key because the two mean
/// different things on the wire: a missing key leaves the server's existing
/// value alone, while an explicit null clears it. `mergeAttributes` drops
/// Swift `nil`s for exactly that reason — see `Context.swift`.
public enum AttrValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

// MARK: - Literal ergonomics
//
// Without these every call site reads
// `["plan": .string("pro"), "seats": .number(3)]`, which is enough friction
// that integrations start stringifying everything and lose type fidelity on
// the server. With them it is `["plan": "pro", "seats": 3]`.

extension AttrValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension AttrValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension AttrValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension AttrValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension AttrValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Wire format

extension AttrValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            // Bool must be tried before Double. JSONDecoder will happily decode
            // `true` as 1.0, so testing Double first would turn every boolean
            // attribute into a number and break segment rules written against
            // `is true`.
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a string, number, boolean or null."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension AttrValue {
    /// Integer convenience for counters and epoch-millisecond timestamps.
    ///
    /// Safe for both: `Double` carries 53 bits of integer precision, and a
    /// millisecond timestamp is ~41 bits until well past the year 10000.
    public static func int(_ value: Int) -> AttrValue { .number(Double(value)) }
}
