import XCTest

@testable import RetainzaSDK

/// `CollectionItem` exists to put ONE shape on the wire, whichever spelling the
/// host app used. These assert the encoding rather than the Swift type, because
/// the encoding is the part the server has an opinion about.
final class CollectionItemTests: XCTestCase {
    private func encode(_ item: CollectionItem) throws -> [String: Any] {
        let data = try JSONEncoder().encode(item)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEncodesFlat_idAlongsideFieldsNotNested() throws {
        let json = try encode(CollectionItem("lagos_10k", ["status": "done", "progress": 100]))

        XCTAssertEqual(json["id"] as? String, "lagos_10k")
        XCTAssertEqual(json["status"] as? String, "done")
        XCTAssertEqual(json["progress"] as? Double, 100)
        XCTAssertEqual(json.count, 3, "fields must sit beside id, not under a 'fields' key")
    }

    func testIdOnlyItemEncodesToJustAnId() throws {
        let json = try encode(CollectionItem("lagos_10k"))
        XCTAssertEqual(json as NSDictionary, ["id": "lagos_10k"] as NSDictionary)
    }

    /// The shorthand: `let items: [CollectionItem] = ["a", "b"]`.
    func testStringLiteralIsAnIdOnlyItem() throws {
        let item: CollectionItem = "lagos_10k"
        XCTAssertEqual(item, CollectionItem("lagos_10k"))

        let list: [CollectionItem] = ["a", "b"]
        XCTAssertEqual(list.map(\.id), ["a", "b"])
    }

    /// Both are server-owned. Building a request that carries them would earn a
    /// 400, so they are dropped at encode time rather than sent and refused.
    func testReservedFieldNamesAreDropped() throws {
        let json = try encode(CollectionItem("c1", ["id": "hijack", "updated_at": 1, "status": "done"]))

        XCTAssertEqual(json["id"] as? String, "c1", "a field named id must not overwrite the merge key")
        XCTAssertNil(json["updated_at"], "updated_at is stamped by the server")
        XCTAssertEqual(json["status"] as? String, "done")
    }

    func testEveryAttrValueCaseSurvivesEncoding() throws {
        let json = try encode(CollectionItem("c1", [
            "s": "text",
            "n": 42,
            "b": true,
            "nothing": .null,
        ]))

        XCTAssertEqual(json["s"] as? String, "text")
        XCTAssertEqual(json["n"] as? Double, 42)
        XCTAssertEqual(json["b"] as? Bool, true)
        XCTAssertTrue(json["nothing"] is NSNull)
    }

    func testCollectionsQueuePathExists() {
        // The offline queue only replays paths it can name. Without this case a
        // collection write would be dropped on a flush after a restart.
        XCTAssertEqual(QueuePath.collections.rawValue, "/collections")
        XCTAssertEqual(QueuePath(rawValue: "/collections"), .collections)
    }
}
