// Adapted from Churchfront Video (Copyright 2026 Churchfront LLC) for the standalone Camera Tracker.
struct FramingRule: Codable, Hashable {
    var eyeLine: Double?
    var scale: Double?
    var leadRoom: Double?
    var deadX: Double?
    var deadY: Double?

}

/// Tracking response, for tuning while it runs. Any left out use the built-in values.
/// correction: pull toward the framing mark (1.2); latency: how far behind the preview picture
/// runs, in seconds (0.45); walkThreshold: how fast (frames a second) counts as walking (0.12);
/// zoomThreshold: how wrong the size must look before zooming, as a log ratio (0.3, about a third);
/// zoomWait: seconds it must stay wrong first (1.5).
struct TrackTuning: Codable, Hashable {
    var correction: Double?
    var latency: Double?
    var walkThreshold: Double?
    var zoomThreshold: Double?
    var zoomWait: Double?
}

struct TrackingSettings {
    var trackSpeed = 0.65
    var trackTilt = true
    var trackZoom = false
    var trackTuning = TrackTuning()
}
