// Adapted from Churchfront Video (Copyright 2026 Churchfront LLC) for the standalone Camera Tracker.
import CoreGraphics
import XCTest
@testable import CameraTracker

/// Telling people apart: which person in a new frame is the one being followed.
final class IdentityMatchTests: XCTestCase {
    typealias C = IdentityMatch.Candidate
    let learned = IdentityMatch.Model(own: 0.2, others: 0.9)

    /// Two people cross. The other person is now nearer to where the followed one was, but
    /// the followed one still looks like themselves: stay with them.
    func testCrossingKeepsThePersonWhoLooksRight() {
        let people = [C(position: 0.03, appearance: 0.9), C(position: 0.12, appearance: 0.2)]
        XCTAssertEqual(IdentityMatch.choose(people, reach: 0.4, gone: 0.1, model: learned), .take(1, sure: true))
    }

    /// Two people who look alike (a band in black): carry on by position while they're in
    /// sight, without learning from it, and don't guess after a gap.
    func testLookAlikesFallBackToPositionThenWait() {
        let people = [C(position: 0.05, appearance: 0.50), C(position: 0.2, appearance: 0.55)]
        XCTAssertEqual(IdentityMatch.choose(people, reach: 0.4, gone: 0.1, model: learned), .take(0, sure: false))
        XCTAssertEqual(IdentityMatch.choose(people, reach: 0.4, gone: 2, model: learned), .wait)
    }

    /// The followed person walked off and someone else is standing where they were.
    func testAStrangerInTheGapIsNotPickedUp() {
        XCTAssertEqual(IdentityMatch.choose([C(position: 0.05, appearance: 0.85)], reach: 0.5, gone: 3, model: learned), .wait)
    }

    func testTheRightPersonComingBackIsPickedUp() {
        XCTAssertEqual(IdentityMatch.choose([C(position: 0.3, appearance: 0.3)], reach: 0.5, gone: 3, model: learned), .take(0, sure: true))
    }

    /// Too small to tell apart, or nothing learned yet: the nearest person, as before.
    func testWithoutLooksItFollowsTheNearest() {
        let people = [C(position: 0.3, appearance: nil), C(position: 0.1, appearance: nil)]
        XCTAssertEqual(IdentityMatch.choose(people, reach: 0.4, gone: 0.1, model: .init()), .take(1, sure: false))
        XCTAssertEqual(IdentityMatch.choose([C(position: 0.1, appearance: 0.4)], reach: 0.4, gone: 3, model: .init()), .take(0, sure: false))
    }

    func testNobodyWithinReachWaits() {
        XCTAssertEqual(IdentityMatch.choose([C(position: 0.6, appearance: 0.1)], reach: 0.4, gone: 0.1, model: learned), .wait)
        XCTAssertEqual(IdentityMatch.choose([], reach: 0.4, gone: 0.1, model: learned), .wait)
    }

    /// Before the others' look is known the limit is generous; never tighter than the measured floor.
    func testLimit() {
        XCTAssertNil(IdentityMatch.Model().limit)
        XCTAssertEqual(IdentityMatch.Model(own: 0.1).limit!, 0.6, accuracy: 0.001)
        XCTAssertEqual(IdentityMatch.Model(own: 0.2, others: 0.9).limit!, 0.55, accuracy: 0.001)
    }

    /// Following by name: the best fit, only if clearly better than the next person.
    func testFindingANamedPerson() {
        XCTAssertEqual(IdentityMatch.find([0.8, 0.3, 0.9]), 1)
        XCTAssertNil(IdentityMatch.find([0.5, 0.52]))
        XCTAssertEqual(IdentityMatch.find([nil]), 0)       // the only person in the shot
        XCTAssertNil(IdentityMatch.find([nil, nil]))
        XCTAssertNil(IdentityMatch.find([0.9, nil]))       // one unknown, one who looks wrong
        XCTAssertNil(IdentityMatch.find([]))
    }
}

final class AppearanceTests: XCTestCase {
    func picture() -> CGImage {
        let w = 640, h = 360
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Left: red and white stripes. Right: a blue block with a yellow circle.
        for i in 0..<10 {
            ctx.setFillColor(i % 2 == 0 ? CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 60 + i * 12, y: 60, width: 12, height: 240))
        }
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 420, y: 60, width: 120, height: 240))
        ctx.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 440, y: 120, width: 80, height: 80))
        return ctx.makeImage()!
    }

    func testLooksCompare() throws {
        let img = picture()
        let left = CGRect(x: 60.0 / 640, y: 60.0 / 360, width: 120.0 / 640, height: 240.0 / 360)
        let right = CGRect(x: 420.0 / 640, y: 60.0 / 360, width: 120.0 / 640, height: 240.0 / 360)
        let a = try XCTUnwrap(Appearance.of(img, box: left))
        let nudged = try XCTUnwrap(Appearance.of(img, box: left.offsetBy(dx: 0.01, dy: 0.01)))
        let b = try XCTUnwrap(Appearance.of(img, box: right))
        let same = try XCTUnwrap(a.distance(to: nudged)), other = try XCTUnwrap(a.distance(to: b))
        XCTAssertLessThan(same, other * 0.8, "the same thing nudged should look far more alike than a different thing")
        XCTAssertNil(Appearance.of(img, box: CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.01)), "too small to tell")
    }

    func testNoPeopleInAnEmptyPicture() {
        XCTAssertTrue(AutoTracker.detect(picture()).isEmpty)
    }
}

final class TrackingMotionTests: XCTestCase {
    func testSmallDeviationsHoldAndLargeDeviationsUseTheSameLowSpeed() {
        XCTAssertNil(TrackingMotion.correction(panError: 0.10, tiltError: -0.08))
        XCTAssertEqual(TrackingMotion.correction(panError: 0.15, tiltError: 0),
                       TrackingMotion.correction(panError: 0.65, tiltError: 0))
        let opposite = TrackingMotion.correction(panError: -0.22, tiltError: 0.2)
        XCTAssertEqual(opposite?.pan, -0.28)
        XCTAssertEqual(opposite?.tilt, 0.24)
    }

    func testUnconfirmedOrMismatchedSubjectDoesNotResumeAfterGap() {
        XCTAssertFalse(TrackingMotion.canKeepSubject(gap: 1, confirmedAppearance: false, distance: nil))
        XCTAssertFalse(TrackingMotion.canKeepSubject(gap: 0.2, confirmedAppearance: false, distance: 0.9))
        XCTAssertTrue(TrackingMotion.canKeepSubject(gap: 1, confirmedAppearance: true, distance: 0.25))
    }
}
