import XCTest
@testable import Ripples

final class RipplesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Ripples.shared.reset()
    }

    private func setupWithFreshToken() {
        let token = UUID().uuidString
        let config = RipplesConfig(projectToken: token)
        config.flushIntervalSeconds = 0
        config.flushAt = 999
        Ripples.setup(config)
    }

    func testIdentifyAndTrackEnqueue() {
        setupWithFreshToken()

        Ripples.shared.identify("user_1", traits: ["email": "a@b.com"])
        Ripples.shared.track("did_thing", properties: ["area": "x"])

        XCTAssertEqual(Ripples.shared.queueDepth, 2)
    }

    /// identify() persists user_id so later track/screen calls carry $user_id
    /// without the host app having to re-identify on every session.
    func testUserIdInjectedOnSubsequentEvents() {
        setupWithFreshToken()

        Ripples.shared.identify("user_42", traits: [:])
        Ripples.shared.track("did_thing")
        Ripples.shared.screen("Home")

        let props = Ripples.shared.lastEnqueuedProperties
        XCTAssertEqual(props?["$user_id"] as? String, "user_42")
    }

    /// group() sends the group's properties once, then every later event
    /// carries $groups; the group identify itself carries none.
    func testGroupAttachedToSubsequentEvents() {
        setupWithFreshToken()

        Ripples.shared.group("Company", key: "acme_42", properties: ["name": "Acme"])
        let identify = Ripples.shared.lastEnqueuedProperties
        XCTAssertEqual(identify?["$type"] as? String, "group")
        XCTAssertEqual(identify?["$group_type"] as? String, "company")
        XCTAssertEqual(identify?["$group_key"] as? String, "acme_42")
        XCTAssertEqual((identify?["$group_properties"] as? [String: Any])?["name"] as? String, "Acme")
        XCTAssertNil(identify?["$groups"])

        Ripples.shared.track("created a report")
        let track = Ripples.shared.lastEnqueuedProperties
        XCTAssertEqual(track?["$groups"] as? [String: String], ["company": "acme_42"])
    }

    func testResetGroupsStopsAttachingThem() {
        setupWithFreshToken()

        Ripples.shared.group("company", key: "acme_42")
        Ripples.shared.resetGroups()
        Ripples.shared.track("created a report")

        XCTAssertNil(Ripples.shared.lastEnqueuedProperties?["$groups"])
    }

    func testGroupWithEmptyKeyIsIgnored() {
        setupWithFreshToken()

        Ripples.shared.group("company", key: "")

        XCTAssertEqual(Ripples.shared.queueDepth, 0)
    }

    func testEventSerialization() {
        let event = RipplesEvent(type: "track",
                                 properties: ["$name": "x", "$user_id": "u"])
        let data = RipplesEvent.toData(event)
        XCTAssertNotNil(data)

        let decoded = RipplesEvent.fromData(data!)
        XCTAssertEqual(decoded?["$type"] as? String, "track")
        XCTAssertEqual(decoded?["$name"] as? String, "x")
        XCTAssertNotNil(decoded?["$sent_at"])
    }
}
