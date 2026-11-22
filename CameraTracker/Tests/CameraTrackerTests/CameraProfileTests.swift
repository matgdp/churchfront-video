import Foundation
import XCTest
@testable import CameraTracker

final class CameraProfileTests: XCTestCase {
    func testNamedCamerasRoundTripWithIndependentSettings() throws {
        let first = CameraProfile(name: "Stage", host: "192.0.2.10")
        let second = CameraProfile(name: "Wide", host: "192.0.2.11", viscaPort: "5680", rtspPort: "8554", path: "/stream2")
        let encoded = try JSONEncoder().encode([first, second])
        let restored = try JSONDecoder().decode([CameraProfile].self, from: encoded)

        XCTAssertEqual(restored, [first, second])
        XCTAssertEqual(restored[0].streamURL?.absoluteString, "rtsp://192.0.2.10:554/2")
        XCTAssertEqual(restored[1].streamURL?.absoluteString, "rtsp://192.0.2.11:8554/stream2")
    }

    func testValidationNormalizesFieldsAndRejectsInvalidSettings() throws {
        var profile = CameraProfile(name: " Stage ", host: " 192.0.2.10 ")
        let valid = try XCTUnwrap(profile.validated)
        XCTAssertEqual(valid.name, "Stage")
        XCTAssertEqual(valid.host, "192.0.2.10")
        profile.viscaPort = "0"
        XCTAssertNil(profile.validated)
        profile.viscaPort = "5678"
        profile.path = "stream2"
        XCTAssertNil(profile.validated)
    }
}
