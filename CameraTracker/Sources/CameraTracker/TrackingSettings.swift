import Foundation

// Adapted from Churchfront Video (Copyright 2026 Churchfront LLC) for the standalone Camera Tracker.
struct FramingRule: Codable, Hashable {
    var eyeLine: Double?
    var scale: Double?
}

/// Fixed low-speed corrections, spaced far enough apart to see the previous movement.
struct TrackingMotion: Equatable {
    var pan: Double
    var tilt: Double

    static func correction(panError: Double, tiltError: Double) -> Self? {
        let pan = axis(panError, tolerance: 0.12, speed: 0.28)
        let tilt = axis(tiltError, tolerance: 0.09, speed: 0.24)
        return pan == 0 && tilt == 0 ? nil : Self(pan: pan, tilt: tilt)
    }

    static func canKeepSubject(gap: TimeInterval, confirmedAppearance: Bool, distance: Double?) -> Bool {
        if let distance, distance > 0.7 { return false }
        return confirmedAppearance || gap < 0.65
    }

    private static func axis(_ error: Double, tolerance: Double, speed: Double) -> Double {
        guard abs(error) >= tolerance else { return 0 }
        return error > 0 ? speed : -speed
    }
}
