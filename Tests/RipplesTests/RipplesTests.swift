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

    /// group() sends the company with the signed-in user and the traits,
    /// then every later event carries $company_id.
    func testCompanyAttachedToSubsequentEvents() {
        setupWithFreshToken()

        Ripples.shared.identify("user_1")
        Ripples.shared.group("acme_42", traits: ["name": "Acme"])
        let call = Ripples.shared.lastEnqueuedProperties
        XCTAssertEqual(call?["$type"] as? String, "group")
        XCTAssertEqual(call?["$company_id"] as? String, "acme_42")
        XCTAssertEqual(call?["$user_id"] as? String, "user_1")
        XCTAssertEqual((call?["$traits"] as? [String: Any])?["name"] as? String, "Acme")

        Ripples.shared.track("created a report")
        XCTAssertEqual(Ripples.shared.lastEnqueuedProperties?["$company_id"] as? String, "acme_42")
    }

    func testResetGroupStopsAttachingTheCompany() {
        setupWithFreshToken()

        Ripples.shared.group("acme_42")
        Ripples.shared.resetGroup()
        Ripples.shared.track("created a report")

        XCTAssertNil(Ripples.shared.lastEnqueuedProperties?["$company_id"])
    }

    func testGroupWithEmptyIdIsIgnored() {
        setupWithFreshToken()

        Ripples.shared.group("")

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
