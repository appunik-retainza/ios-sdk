import Foundation

/// One element of a **collection** — one-to-many custom data, such as a user's
/// challenges, badges or saved searches.
///
/// ```swift
/// // Just an id, when the list is names and nothing else:
/// try await Retainza.shared?.addToCollection("challenges", id: "lagos_10k")
///
/// // With fields, when a campaign has to FIND things in the list:
/// try await Retainza.shared?.addToCollection(
///     "challenges",
///     item: CollectionItem("lagos_10k", ["status": "done", "progress": 100])
/// )
/// ```
///
/// `id` is supplied by YOUR app and is the merge key: writing the same id twice
/// updates that item in place rather than appending. That is what makes a write
/// replayed from the offline queue idempotent — without it, a phone that was
/// offline would end up with the same challenge four times.
///
/// `fields` are FLAT `AttrValue`s. An item field compares in a segment with
/// exactly the same operators as a profile attribute, which is only true
/// because it has the same type. Nesting is rejected by the server.
///
/// Deliberately a parallel type rather than a new `AttrValue` case: adding one
/// would turn every exhaustive `switch` over `AttrValue` — in this SDK and in
/// yours — into a compile error, for a feature most integrations will not use.
///
/// `updated_at` is stamped by the server and may not be supplied.
public struct CollectionItem: Sendable, Equatable {
    public let id: String
    public let fields: [String: AttrValue]

    public init(_ id: String, _ fields: [String: AttrValue] = [:]) {
        self.id = id
        self.fields = fields
    }
}

// MARK: - Literal ergonomics
//
// `["lagos_10k", "strength_block"]` reads as a list of challenges; the
// `CollectionItem("lagos_10k")` spelling at every call site does not.

extension CollectionItem: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

// MARK: - Wire format

extension CollectionItem: Encodable {
    /// Encoded FLAT — `id` alongside the fields, not nested under a key — which
    /// is the shape `POST /v1/collections` accepts and the shape the server
    /// stores. The dynamic keys are why this is hand-rolled rather than
    /// synthesised.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(id, forKey: DynamicKey("id"))
        for (key, value) in fields {
            // `id` and `updated_at` are the merge key and the server's stamp;
            // a field of either name would be refused with a 400, so drop it
            // here rather than building a request that cannot succeed.
            guard key != "id", key != "updated_at" else { continue }
            try container.encode(value, forKey: DynamicKey(key))
        }
    }
}

/// A `CodingKey` for keys only known at runtime.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
