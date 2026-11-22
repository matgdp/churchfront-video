// Adapted from Churchfront Video (Copyright 2026 Churchfront LLC) for the standalone Camera Tracker.
import Foundation
import Combine
import Vision
import CameraControl

/// The three follow shots a broadcast camera operator works with, and how each is framed.
///
/// Framing follows standard broadcast practice:
/// - Eyes sit on or near the upper third line, with modest headroom (more room above the
///   head on wide shots, less on close ones), never the head in the middle of the frame.
/// - Frame edges cut between joints, not at them: a shoulders-up shot ends at mid-chest,
///   a waist-up shot just below the waist, a full-length shot leaves a little room under
///   the feet. Never at the neck, elbows, knees or ankles.
/// - Lead room (looking or walking room): a person facing or moving to one side gets more
///   space on that side, so they aren't walking into the edge of the frame.
/// - The camera doesn't chase every small move. It lets the person move a little inside the
///   frame, eases into and out of each move, and settles rather than hunting.
/// - Shot size stays consistent as people walk nearer or farther, with slow zooms.
///
/// Sizes are measured by the head: the drop from the eyes to the shoulders as a share of the
/// frame height. That stays visible in every shot size, and grows as the shot gets tighter.
enum ShotSize: String, CaseIterable, Identifiable {
    case shoulders, waist, full
    var id: String { rawValue }

    var name: String {
        switch self {
        case .shoulders: return "Shoulders up"
        case .waist: return "Waist up"
        case .full: return "Full length"
        }
    }
    var short: String {
        switch self { case .shoulders: return "Close"; case .waist: return "Waist"; case .full: return "Full" }
    }

    /// The built-in framing rule for this size.
    var standard: FramingRule {
        switch self {
        case .shoulders: return FramingRule(eyeLine: 0.29, scale: 0.36)
        case .waist: return FramingRule(eyeLine: 0.29, scale: 0.21)
        case .full: return FramingRule(eyeLine: 0.12, scale: 0.097)
        }
    }

    /// Where the eyes sit, down from the top of the frame (0 to 1).
    var eyeLine: Double { standard.eyeLine ?? 0.3 }
    /// Eyes to shoulders as a share of frame height, the standard for this size.
    var scale: Double { standard.scale ?? 0.2 }
    /// The size a framing is closest to, from its head scale and what's in shot.
    static func classify(scale: Double?, anklesInShot: Bool, hipsInShot: Bool) -> ShotSize? {
        if let s = scale {
            if s < 0.145 { return .full }      // between the full and waist standards
            if s < 0.275 { return anklesInShot ? .full : .waist }
            return hipsInShot ? .waist : .shoulders
        }
        if anklesInShot { return .full }
        return hipsInShot ? .waist : nil
    }
}

/// One person found in a frame. Coordinates are normalized with the origin top left.
struct TrackedPerson {
    var box: CGRect
    /// Between the eyes (or the nose, or the ears).
    var eye: CGPoint
    /// Eyes to shoulders, as a share of frame height. Nil when the body landmarks aren't clear.
    var scale: Double?
    var hipsInShot = false
    var anklesInShot = false
    /// -1 facing left in the picture, 1 facing right, 0 toward the camera or unclear.
    var facing = 0
    /// What they look like, for telling people apart. Nil when they're too small to tell.
    var appearance: Appearance?

    var size: ShotSize? { ShotSize.classify(scale: scale, anklesInShot: anklesInShot, hipsInShot: hipsInShot) }
}

/// Auto tracking: a camera follows one person around the stage.
///
/// It watches the camera preview, finds people and their
/// body landmarks in each frame with Apple's Vision framework, keeps hold of the one it was
/// told to follow, works out whether the shot is shoulders up, waist up or full length, and
/// pans, tilts and optionally zooms to frame them the way a broadcast operator would (see
/// ShotSize). Any manual move of that camera (joystick, shot, preset, home) ends tracking at
/// once. Manual zoom also stops tracking.
final class AutoTracker: ObservableObject {

    enum Phase: String { case starting, following, searching, lost }

    struct Session {
        let camera: UUID
        let token = UUID()
        var phase: Phase = .starting
        var target: TrackedPerson?
        /// The shot it's framing to, and the head scale to hold (the standard for the size,
        /// or whatever the volunteer zoomed to).
        var size: ShotSize = .waist
        var holdScale: Double?
        /// What the person asked for; nil means work it out from the shot when tracking starts.
        var asked: ShotSize?
        var pick: CGPoint?
        var eye: CGPoint?
        var lastSeen = Date()
        var started = Date()
        var readyAfter = Date.distantPast
        var proposedMove: TrackingMotion?
        var zoomWrongSince: Date?
        var zoomReadyAfter = Date.distantPast

        var gallery: [Appearance] = []
        var anchors = 1
        var galleryAt = Date.distantPast
        /// How much their own look varies, and how different the people near them look.
        var ownLook: Double?, otherLook: Double?
        /// Since when they've been the only person around (then it's safe to learn their look).
        var aloneSince: Date?
    }

    @Published private(set) var sessions: [UUID: Session] = [:]

    private var feeds: [UUID: AnyCancellable] = [:]
    private var busy = false
    private var waiters: [UUID: [(String?) -> Void]] = [:]
    private var timer: Timer?
    private let vision = DispatchQueue(label: "camera-tracker.vision", qos: .userInitiated)

    private let ptz: PTZController
    var autoZoom = false

    init(ptz: PTZController) { self.ptz = ptz; attach() }

    /// Hooks the tracker to the camera controls. Called once at launch.
    func attach() {
        ptz.onManualMove = { [weak self] id in self?.stop(id) }
        ptz.onManualZoom = { [weak self] id in self?.stop(id) }
    }


    /// Start following someone on a camera. `point` (0 to 1, top left) picks the person
    /// nearest it; without one, the person nearest the middle. `size` frames them as that
    /// shot; without one, as whichever shot the camera is closest to now. `done` gets nil
    /// once someone is found, or the reason no one was.
    func start(_ camera: PTZCamera, frames: AnyPublisher<CGImage, Never>,
               at point: CGPoint? = nil, size: ShotSize? = nil, done: ((String?) -> Void)? = nil) {
        stop(camera.id)
        var s = Session(camera: camera.id)
        s.pick = point
        s.asked = size
        if let a = s.asked { s.size = a }
        sessions[camera.id] = s
        if let done { waiters[camera.id, default: []].append(done) }
        feeds[camera.id] = frames.sink { [weak self] img in self?.frame(img, camera.id) }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    /// Reframe a tracking camera as a different shot size.
    func setSize(_ id: UUID, _ size: ShotSize) {
        guard var s = sessions[id] else { return }
        s.asked = size
        s.size = size
        s.holdScale = size.scale
        // A size picked on purpose reframes now, without the usual wait.
        s.zoomWrongSince = .distantPast
        sessions[id] = s
    }

    func stop(_ id: UUID) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        feeds[id] = nil
        ptz.cancelTrackingMotion(camera: id)
        finish(id, "Tracking was stopped.")
        if sessions.isEmpty { timer?.invalidate(); timer = nil }
    }

    func stopAll() { for id in sessions.keys { stop(id) } }

    // MARK: Frames

    private func frame(_ img: CGImage, _ id: UUID) {
        guard let session = sessions[id], session.phase != .lost, Date() >= session.readyAfter, !busy else { return }
        let token = session.token, readyAfter = session.readyAfter
        busy = true
        vision.async { [weak self] in
            let people = Self.detect(img)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard let current = self.sessions[id], current.token == token,
                      current.phase != .lost, current.readyAfter == readyAfter else { return }
                self.update(id, people)
            }
        }
    }

    /// People in a frame, with their landmarks where Vision can see them.
    static func detect(_ img: CGImage) -> [TrackedPerson] {
        let pose = VNDetectHumanBodyPoseRequest()
        let rects = VNDetectHumanRectanglesRequest()
        rects.upperBodyOnly = true
        do { try VNImageRequestHandler(cgImage: img).perform([pose, rects]) } catch { return [] }

        var found: [TrackedPerson] = []
        for o in pose.results ?? [] {
            guard let pts = try? o.recognizedPoints(.all) else { continue }
            func at(_ j: VNHumanBodyPoseObservation.JointName, _ min: Float = 0.3) -> CGPoint? {
                guard let p = pts[j], p.confidence >= min else { return nil }
                return CGPoint(x: p.location.x, y: 1 - p.location.y)
            }
            func mid(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
                switch (a, b) {
                case let (a?, b?): return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                default: return a ?? b
                }
            }
            let eyes = mid(at(.leftEye), at(.rightEye))
            let ears = mid(at(.leftEar), at(.rightEar))
            guard let eye = eyes ?? at(.nose) ?? ears else { continue }
            let ls = at(.leftShoulder), rs = at(.rightShoulder)
            let shoulders = mid(ls, rs) ?? at(.neck)
            let all = pts.values.filter { $0.confidence >= 0.3 }.map { CGPoint(x: $0.location.x, y: 1 - $0.location.y) }
            guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(), let maxY = all.map(\.y).max() else { continue }
            // Shot size in one unit (the eyes-to-shoulders drop), measured from the longest span in
            // view, since a small span is only a few pixels on a wide shot: eyes to ankles (about
            // 7.8 times eyes to shoulders on a standing adult), eyes to hips (about 3.7 times;
            // both measured on the stage cameras with Vision's own joints),
            // else eyes to shoulders. Taking the larger of the long spans keeps someone sitting
            // down (whose eyes-to-ankles is shorter) from looking far away.
            let hip = mid(at(.leftHip), at(.rightHip)) ?? at(.root)
            let ankle = mid(at(.leftAnkle), at(.rightAnkle))
            var long: [Double] = []
            if let a = ankle, a.y - eye.y > 0.05 { long.append(Double(a.y - eye.y) / 7.8) }
            if let h = hip, h.y - eye.y > 0.03 { long.append(Double(h.y - eye.y) / 3.7) }
            let short = shoulders.map { Double($0.y - eye.y) }.flatMap { $0 > 0.01 ? $0 : nil }
            let scale: Double? = long.max() ?? short
            // Top of the head is about half the eyes-to-shoulders drop above the eyes.
            let top = eye.y - CGFloat(scale ?? 0.05) * 0.6
            var p = TrackedPerson(box: CGRect(x: minX, y: top, width: max(0.02, maxX - minX), height: max(0.02, maxY - top)),
                                  eye: eye, scale: scale)
            p.hipsInShot = at(.root) != nil || at(.leftHip) != nil || at(.rightHip) != nil
            p.anklesInShot = at(.leftAnkle) != nil || at(.rightAnkle) != nil
            // Facing: the nose sits off the line between the shoulders on the side they face.
            if let nose = at(.nose), let l = ls, let r = rs {
                let w = abs(l.x - r.x)
                let off = (nose.x - (l.x + r.x) / 2) / max(w, 0.01)
                if w > 0.02, abs(off) > 0.3 { p.facing = off > 0 ? 1 : -1 }
            } else if at(.leftEar) != nil, at(.rightEar) == nil, let n = at(.nose), let e = at(.leftEar) {
                p.facing = n.x > e.x ? 1 : -1  // profile: only one ear shows
            } else if at(.rightEar) != nil, at(.leftEar) == nil, let n = at(.nose), let e = at(.rightEar) {
                p.facing = n.x > e.x ? 1 : -1
            }
            found.append(p)
        }
        // People too small or turned away for landmarks still show as a body: follow them by
        // their outline (no shot size or zoom from these).
        for r in rects.results ?? [] where r.confidence > 0.3 {
            let b = r.boundingBox
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            if found.contains(where: { $0.box.intersects(box) && box.contains($0.eye) }) { continue }
            found.append(TrackedPerson(box: box, eye: CGPoint(x: box.midX, y: box.minY + box.height * 0.12)))
        }
        // What each person looks like (the biggest few in the shot), to tell them apart.
        let biggest = found.indices.sorted { found[$0].box.width * found[$0].box.height > found[$1].box.width * found[$1].box.height }
        for i in biggest.prefix(6) { found[i].appearance = Appearance.of(img, box: found[i].box) }
        return found
    }

    private func update(_ id: UUID, _ people: [TrackedPerson]) {
        guard var s = sessions[id] else { return }
        let now = Date()

        if s.target == nil {
            let p = s.pick ?? CGPoint(x: 0.5, y: 0.5)
            let eligible = s.pick == nil ? people : people.filter { $0.box.insetBy(dx: -0.035, dy: -0.035).contains(p) }
            let pick = eligible.min { dist($0.box.center, p) < dist($1.box.center, p) }
            if let pick {
                s.target = pick
                s.eye = pick.eye
                // Frame as asked; otherwise keep the shot the volunteer set up: its size class for
                // headroom and lead room, and its exact size to hold (no zoom at the start).
                s.size = s.asked ?? pick.size ?? .waist
                s.holdScale = s.asked != nil ? s.size.scale : pick.scale
                s.lastSeen = now
                s.phase = .following
                if s.gallery.isEmpty, let look = pick.appearance { s.gallery = [look]; s.anchors = 1; s.galleryAt = now }
                sessions[id] = s
                finish(id, nil)
                return
            }
            sessions[id] = s
            if now.timeIntervalSince(s.started) > 4 {
                finish(id, "No person found. Tracking stopped.")
                stop(id)
            }
            return
        }

        // Keep hold of the same person: by where they were and by what they look like.
        let last = s.target!
        let gone = max(0, now.timeIntervalSince(max(s.lastSeen, s.readyAfter)))
        let reach = min(0.22, max(0.10, last.box.width * 0.65))
        let candidates = people.map { p in
            IdentityMatch.Candidate(position: dist(p.box.center, last.box.center),
                                    appearance: s.gallery.isEmpty ? nil : p.appearance?.distance(to: s.gallery))
        }
        let choice = IdentityMatch.choose(candidates, reach: reach, gone: gone, model: .init(own: s.ownLook, others: s.otherLook))
        if case let .take(i, sure) = choice,
           TrackingMotion.canKeepSubject(gap: gone, confirmedAppearance: sure, distance: candidates[i].appearance) {
            let next = people[i]
            learn(&s, next, candidates, i, sure: sure, reach: reach, gone: gone, now: now)
            s.target = next
            s.lastSeen = now
            s.phase = .following
            let o = s.eye ?? next.eye
            s.eye = CGPoint(x: o.x + (next.eye.x - o.x) * 0.5, y: o.y + (next.eye.y - o.y) * 0.4)
            steer(&s, next, now: now)
        } else {
            ptz.cancelTrackingMotion(camera: id)
            s.proposedMove = nil
            s.zoomWrongSince = nil
            s.phase = gone > 2 ? .lost : .searching
        }
        sessions[id] = s
    }

    /// Learns what the followed person looks like, only from frames where it's certain who
    /// they are: their look confirmed it, or they've been the only person around for a second.
    /// Two people crossing never teaches it the wrong one.
    private func learn(_ s: inout Session, _ next: TrackedPerson, _ candidates: [IdentityMatch.Candidate], _ i: Int,
                       sure: Bool, reach: Double, gone: Double, now: Date) {
        let alone = candidates.filter { $0.position < reach * 1.5 }.count == 1
        if !alone { s.aloneSince = nil } else if s.aloneSince == nil { s.aloneSince = now }
        let settled = gone < 0.7 && (s.aloneSince.map { now.timeIntervalSince($0) > 1 } ?? false)
        guard sure || settled, let look = next.appearance else { return }
        if let d = candidates[i].appearance { s.ownLook = s.ownLook.map { $0 + (d - $0) * 0.2 } ?? d }
        if sure {
            for (j, c) in candidates.enumerated() where j != i && c.position < reach * 1.5 {
                if let d = c.appearance { s.otherLook = s.otherLook.map { $0 + (d - $0) * 0.2 } ?? d }
            }
        }
        guard now.timeIntervalSince(s.galleryAt) > 0.7 else { return }
        s.galleryAt = now
        if s.gallery.count >= 6, s.gallery.count > s.anchors { s.gallery.remove(at: s.anchors) }
        if s.gallery.count < 6 { s.gallery.append(look) }
    }

    private func steer(_ s: inout Session, _ person: TrackedPerson, now: Date) {
        guard let eye = s.eye else { return }
        let motion = TrackingMotion.correction(panError: eye.x - 0.5, tiltError: s.size.eyeLine - eye.y)
        if motion != nil {
            s.zoomWrongSince = nil
        }
        if let motion, motion == s.proposedMove {
            s.proposedMove = nil
            s.readyAfter = now.addingTimeInterval(1.1)
            ptz.trackPulse(pan: motion.pan, tilt: motion.tilt, duration: 0.15, camera: s.camera)
            return
        }
        s.proposedMove = motion

        guard motion == nil, autoZoom, now >= s.zoomReadyAfter,
              let target = s.holdScale, let measured = person.scale, target > 0, measured > 0,
              abs(log(target / measured)) > 0.3 else {
            s.zoomWrongSince = nil
            return
        }
        let since = s.zoomWrongSince ?? now
        s.zoomWrongSince = since
        guard now.timeIntervalSince(since) >= 1.5 else { return }
        s.zoomWrongSince = nil
        s.zoomReadyAfter = now.addingTimeInterval(3)
        s.readyAfter = now.addingTimeInterval(1.2)
        ptz.trackPulse(zoom: target > measured ? 0.15 : -0.15, duration: 0.15, camera: s.camera)
    }

    private func tick() {
        let now = Date()
        let expired = sessions.values.filter { $0.target == nil && now.timeIntervalSince($0.started) > 4 }
        for s in expired {
            finish(s.camera, "No person found. Tracking stopped.")
            stop(s.camera)
        }
        for (id, var session) in sessions where session.target != nil && session.phase != .lost
            && now.timeIntervalSince(max(session.lastSeen, session.readyAfter)) > 2 {
            ptz.cancelTrackingMotion(camera: id)
            session.phase = .lost
            sessions[id] = session
        }
    }

    private func finish(_ id: UUID, _ why: String?) {
        guard let w = waiters.removeValue(forKey: id) else { return }
        for f in w { f(why) }
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

