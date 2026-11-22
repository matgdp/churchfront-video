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
        case .shoulders: return FramingRule(eyeLine: 0.29, scale: 0.36, leadRoom: 0.09, deadX: 0.08, deadY: 0.05)
        case .waist: return FramingRule(eyeLine: 0.29, scale: 0.21, leadRoom: 0.11, deadX: 0.07, deadY: 0.05)
        case .full: return FramingRule(eyeLine: 0.12, scale: 0.097, leadRoom: 0.13, deadX: 0.06, deadY: 0.04)
        }
    }

    /// Where the eyes sit, down from the top of the frame (0 to 1).
    var eyeLine: Double { standard.eyeLine ?? 0.3 }
    /// Eyes to shoulders as a share of frame height, the standard for this size.
    var scale: Double { standard.scale ?? 0.2 }
    /// How far off center a person facing or walking one way sits, giving lead room.
    var leadRoom: Double { standard.leadRoom ?? 0.1 }
    /// How far they can drift across or up and down before the camera moves.
    var deadX: Double { standard.deadX ?? 0.07 }
    var deadY: Double { standard.deadY ?? 0.08 }

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
/// pans, tilts and (gently) zooms to frame them the way a broadcast operator would (see
/// ShotSize). Any manual move of that camera (joystick, shot, preset, home) ends tracking at
/// once. Zooming by hand keeps tracking going and makes that zoom the size to hold.
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
        /// What the picture is right now.
        var seen: ShotSize?
        var pick: CGPoint?
        var people: [TrackedPerson] = []
        var eye: CGPoint?          // smoothed
        var scale: Double?         // smoothed
        var lead = 0.0             // smoothed lead-room offset
        var lastSeen = Date()
        var started = Date()
        var lastFrame = Date()
        var manualZoomAt: Date?
        var panning = false, tilting = false, zooming = false
        /// Pan and tilt last sent, in the camera's units (hundredths of a degree a second).
        var sentPan = 0.0, sentTilt = 0.0, sentZoom = 0.0
        var panDir = 0, panDirSince = Date()

        // Motion, measured. The camera reports its angle of view, so moves are worked out in
        // real angles: how fast the person is really going, and how fast the camera really
        // turns for the speed it was asked (some Canon modes slow panning when zoomed in).
        var fov = 40.0                       // horizontal angle of view now, degrees
        var lastPos: (pan: Double, tilt: Double, at: Date)?
        var gainPan = 1.0, gainTilt = 1.0    // how fast it really turns ÷ how fast it was asked
        var sentAt = Date()
        var sentLog: [(at: Date, pan: Double, tilt: Double)] = []
        var lastEye: (p: CGPoint, at: Date)?
        var imgVX = 0.0, imgVY = 0.0         // the person's motion in the picture, frames a second
        var moveX = 0.0, moveY = 0.0         // their real motion (right and up), frames a second
        var polling = false
        /// Recent measured positions (degrees), for how fast the camera really moved.
        var polls: [(at: Date, pan: Double, tilt: Double)] = []
        /// Zoom hold, kept calm: when the size first looked wrong, and the last zoom's end and direction.
        var zoomWrongSince: Date?
        var zoomEnded = Date.distantPast
        var zoomDir = 0
        /// For the first moments, the size to hold follows the (smoothed) size they're at.
        var holdLearnUntil = Date.distantPast
        /// Walking: the direction they've been clearly moving, and since when.
        var walkX = 0, walkXSince = Date(), walkY = 0, walkYSince = Date()

        // Who it's following. A few pictures of what they look like (the first `anchors` are
        // kept for good: the ones from the stage scan, or the first sight of them; the rest
        // are the most recent), so the camera stays with them when people cross and waits
        // for them, not the nearest person, after losing sight.
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
    // Concurrent, so cameras tracking at once each get their own frames looked at; `busy` keeps
    // one frame per camera in flight.
    private let vision = DispatchQueue(label: "cuevideo.tracker", qos: .userInitiated, attributes: .concurrent)

    private let ptz: PTZController
    var config = TrackingSettings()

    init(ptz: PTZController) { self.ptz = ptz; attach() }

    /// Hooks the tracker to the camera controls. Called once at launch.
    func attach() {
        ptz.onManualMove = { [weak self] id in self?.stop(id) }
        ptz.onManualZoom = { [weak self] id in self?.manualZoom(id) }
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
        s.manualZoomAt = nil
        // A size picked on purpose reframes now, without the usual wait.
        s.zoomWrongSince = .distantPast
        s.zoomEnded = .distantPast
        s.zoomDir = 0
        sessions[id] = s
    }

    func stop(_ id: UUID) {
        guard let s = sessions[id] else { return }
        sessions[id] = nil
        feeds[id] = nil
        if s.sentPan != 0 || s.sentTilt != 0 { ptz.trackDrive(pan: 0, tilt: 0, camera: id) }
        if s.sentZoom != 0 { ptz.trackZoom(0, camera: id) }
        finish(id, "Tracking was stopped.")
        if sessions.isEmpty { timer?.invalidate(); timer = nil }
    }

    func stopAll() { for id in sessions.keys { stop(id) } }

    /// The volunteer (or Claude) zoomed: stop holding the old size for a moment, then hold the new one.
    private func manualZoom(_ id: UUID) {
        guard var s = sessions[id] else { return }
        s.manualZoomAt = Date()
        s.zooming = false
        s.sentZoom = 0
        sessions[id] = s
    }

    // MARK: Frames

    private func frame(_ img: CGImage, _ id: UUID) {
        guard let token = sessions[id]?.token, !busy else { return }
        busy = true
        vision.async { [weak self] in
            let people = Self.detect(img)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard self.sessions[id]?.token == token else { return }
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
        s.people = people
        s.lastFrame = now

        if s.target == nil {
            let p = s.pick ?? CGPoint(x: 0.5, y: 0.5)
            let pick = people.first { $0.box.contains(p) } ?? people.min { dist($0.box.center, p) < dist($1.box.center, p) }
            if let pick {
                s.target = pick
                s.eye = pick.eye
                s.scale = pick.scale
                s.seen = pick.size
                // Frame as asked; otherwise keep the shot the volunteer set up: its size class for
                // headroom and lead room, and its exact size to hold (no zoom at the start).
                s.size = s.asked ?? pick.size ?? .waist
                s.holdScale = s.asked != nil ? s.size.scale : pick.scale
                s.holdLearnUntil = now.addingTimeInterval(1.5)
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
        let gone = now.timeIntervalSince(s.lastSeen)
        let reach = min(0.5, 0.2 + max(last.box.width, last.box.height) * 0.6 + gone * 0.15)
        let candidates = people.map { p in
            IdentityMatch.Candidate(position: dist(p.box.center, last.box.center),
                                    appearance: s.gallery.isEmpty ? nil : p.appearance?.distance(to: s.gallery))
        }
        let choice = IdentityMatch.choose(candidates, reach: reach, gone: gone, model: .init(own: s.ownLook, others: s.otherLook))
        if case let .take(i, sure) = choice {
            let next = people[i]
            learn(&s, next, candidates, i, sure: sure, reach: reach, gone: gone, now: now)
            s.target = next
            s.lastSeen = now
            s.phase = .following
            let o = s.eye ?? next.eye
            s.eye = CGPoint(x: o.x + (next.eye.x - o.x) * 0.5, y: o.y + (next.eye.y - o.y) * 0.4)
            if let n = next.scale { s.scale = s.scale.map { $0 + (n - $0) * 0.08 } ?? n }
            if let z = next.size { s.seen = z }
            steer(&s, next)
        } else {
            if gone > 0.6 { hold(&s) }
            s.phase = gone > 5 ? .lost : .searching
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

    /// Pan, tilt and zoom toward the framing for this shot size.
    private func steer(_ s: inout Session, _ person: TrackedPerson) {
        guard let eye = s.eye else { return }
        let now = Date()

        // After a manual zoom settles, hold whatever size the volunteer chose.
        if let m = s.manualZoomAt {
            if now.timeIntervalSince(m) > 0.8 {
                s.manualZoomAt = nil
                if let sc = s.scale {
                    s.holdScale = sc
                    s.size = ShotSize.classify(scale: sc, anklesInShot: person.anklesInShot, hipsInShot: person.hipsInShot) ?? s.size
                }
            }
        }
        let size = s.size
        if s.asked == nil, now < s.holdLearnUntil, let sc = s.scale { s.holdScale = sc }

        // Lead room: walking one way (the camera has been panning that way a while) wins over
        // which way they face. Eased so the frame doesn't jump when they turn.
        let dir = s.panDir != 0 && now.timeIntervalSince(s.panDirSince) > 0.7 ? s.panDir : person.facing
        s.lead += (Double(-dir) * size.leadRoom - s.lead) * 0.06
        let markX = 0.5 + s.lead

        let ex = eye.x - markX                 // right of the mark: pan right
        let ey = size.eyeLine - eye.y          // eyes above the line: tilt up
        let k = config.trackSpeed
        let fovX = s.fov, fovY = s.fov * 9 / 16
        let tune = config.trackTuning
        let latency = tune.latency ?? 0.45     // the preview picture (and Vision) run about this far behind

        // How fast they're really moving: their motion in the picture plus the camera's own
        // motion at the time that picture was taken. In frames a second, right and up.
        let dtFrame = min(0.3, max(0.03, s.lastEye.map { now.timeIntervalSince($0.at) } ?? 0.07))
        if let last = s.lastEye {
            let dt = now.timeIntervalSince(last.at)
            if dt > 0.02, dt < 0.6 {
                let vx = (person.eye.x - last.p.x) / dt, vy = (person.eye.y - last.p.y) / dt
                s.imgVX += (vx - s.imgVX) * 0.35
                s.imgVY += (vy - s.imgVY) * 0.35
            } else { s.imgVX = 0; s.imgVY = 0 }
        }
        s.lastEye = (person.eye, now)
        // How fast the person is really moving (frames a second, right and up): their drift in
        // the picture plus how fast the camera was really turning when that picture was taken,
        // measured from its position reads, never assumed from what it was told.
        let ta = now.addingTimeInterval(-latency + 0.05)
        let before = s.polls.filter { $0.at <= ta }
        var camRX = 0.0, camRY = 0.0
        if before.count >= 2 {
            // Over the last three reads (about half a second), so the camera's own starts and
            // stops don't look like the person moving.
            let a = before[max(0, before.count - 3)], b = before[before.count - 1]
            let dt = b.at.timeIntervalSince(a.at)
            if dt > 0.05, dt < 1 { camRX = (b.pan - a.pan) / dt / fovX; camRY = (b.tilt - a.tilt) / dt / fovY }
        }
        s.moveX += ((s.imgVX + camRX) - s.moveX) * 0.2
        s.moveY += ((camRY - s.imgVY) - s.moveY) * 0.2
        // Only clear, steady movement one way for half a second counts as walking; anything
        // smaller is a shift of weight or measurement noise, and the camera just holds framing.
        func walking(_ v: Double, _ dir: inout Int, _ since: inout Date, _ min: Double) -> Double {
            let d = v > min ? 1 : (v < -min ? -1 : 0)
            if d != dir { dir = d; since = now }
            return d != 0 && now.timeIntervalSince(since) > 0.5 ? v : 0
        }
        let walkMin = tune.walkThreshold ?? 0.12
        let walkVX = walking(s.moveX, &s.walkX, &s.walkXSince, walkMin)
        let walkVY = walking(s.moveY, &s.walkY, &s.walkYSince, walkMin * 1.25)
        let relX = s.imgVX, relY = -s.imgVY

        // Edge alarm: how close their body is to the side of the frame they're heading for,
        // 0 (comfortable) to 1 (touching it). Near the edge the camera corrects harder.
        // Their body's edge, or on a tight shot (body wider than half the frame) their head.
        let box = person.box
        let gap = box.width < 0.5 ? (ex > 0 ? 1 - box.maxX : box.minX)
                                  : (ex > 0 ? 1 - eye.x : eye.x) - 0.1
        let urgency = min(1, max(0, (0.2 - gap) / 0.2))

        // Move while they're off the mark or walking; settle once they stand still on it.
        if abs(ex) > size.deadX || walkVX != 0 || urgency > 0 { s.panning = true }
        else if abs(ex) < size.deadX * 0.5 && walkVX == 0 { s.panning = false }
        let tiltOn = config.trackTilt
        if tiltOn, abs(ey) > size.deadY || walkVY != 0 { s.tilting = true }
        else if !tiltOn || (abs(ey) < size.deadY * 0.5 && walkVY == 0) { s.tilting = false }
        _ = (relX, relY)

        // The camera speed to ask for, in frames a second: their own speed, plus a gentle pull
        // toward the mark (stronger near the edge). Tested in simulation against a camera that
        // turns faster or slower than expected and a picture delay of 0.3 to 0.65 s: it keeps
        // up with walking and settles without hunting. Speed-ups are limited so moves start smoothly.
        func rate(_ e: Double, _ move: Double, _ on: Bool, _ prev: Double) -> Double {
            guard on else { return 0 }
            let kp = min(2.5, min(1.6, (tune.correction ?? 1.2) * k) * (1 + 1.5 * urgency))
            let want = move + kp * e
            let accel = (urgency > 0.3 ? 16.0 : 8.0 * max(1, k)) * dtFrame
            let decel = 16.0 * max(1, k) * dtFrame
            let step = abs(want) < abs(prev) || want * prev < 0 ? decel : accel
            return prev + max(-step, min(step, want - prev))
        }
        let camNowX = s.sentPan / 100 * s.gainPan / fovX, camNowY = s.sentTilt / 100 * s.gainTilt / fovY
        let rx = rate(ex, walkVX, s.panning, camNowX)
        let ry = rate(ey, walkVY, s.tilting, camNowY)
        // Back into the camera's units: degrees a second (× 100), allowing for how it really turns.
        func units(_ r: Double, _ fov: Double, _ g: Double) -> Double {
            let raw = r * fov * 100 / max(0.05, g)
            if abs(raw) < 15 { return 0 }
            return (min(10000, max(20, abs(raw))) / 10).rounded() * 10 * (raw < 0 ? -1 : 1)
        }
        let pan = units(rx, fovX, s.gainPan)
        let tilt = units(ry, fovY, s.gainTilt)
        // Walking direction (the way the camera is following), for lead room.
        let d = pan > 150 ? 1 : (pan < -150 ? -1 : 0)
        if d != s.panDir { s.panDir = d; s.panDirSince = now }

        // Hold the shot size as they come nearer or move away, calmly: only when the size has
        // been clearly wrong (over about a third) for 1.5 s, slowly, with a rest of 2 s after
        // each zoom and no reversing within 5 s, so turning, bending or nodding never sets it
        // hunting in and out.
        var zoom = 0.0
        if config.trackZoom, s.manualZoomAt == nil, let hold = s.holdScale, let sc = s.scale, person.scale != nil {
            let r = log(hold / sc)             // positive: they look too small, zoom in
            let dir = r > 0 ? 1 : -1
            if s.zooming {
                if abs(r) < 0.08 || (dir != s.zoomDir) {
                    s.zooming = false; s.zoomEnded = now; s.zoomWrongSince = nil
                }
            } else if abs(r) > (tune.zoomThreshold ?? 0.3) {
                if s.zoomWrongSince == nil { s.zoomWrongSince = now }
                let settled = now.timeIntervalSince(s.zoomEnded) > 2
                let reversing = dir != s.zoomDir && now.timeIntervalSince(s.zoomEnded) < 5
                if now.timeIntervalSince(s.zoomWrongSince!) > (tune.zoomWait ?? 1.5), settled, !reversing {
                    s.zooming = true; s.zoomDir = dir
                }
            } else {
                s.zoomWrongSince = nil
            }
            if s.zooming {
                let v = min(0.45, max(0.04, abs(r) * 0.3))  // faster when far off, gentle near the size
                zoom = ((r > 0 ? v : -v) * 50).rounded() / 50
            }
        } else if s.zooming {
            s.zooming = false; s.zoomEnded = now
        }
        send(&s, pan, tilt, zoom)
    }

    private func hold(_ s: inout Session) {
        s.panning = false; s.tilting = false; s.zooming = false
        send(&s, 0, 0, 0)
    }

    private func send(_ s: inout Session, _ pan: Double, _ tilt: Double, _ zoom: Double) {
        if pan != s.sentPan || tilt != s.sentTilt {
            s.sentPan = pan; s.sentTilt = tilt
            s.sentAt = Date()
            s.sentLog.append((Date(), pan, tilt))
            if s.sentLog.count > 40 { s.sentLog.removeFirst(s.sentLog.count - 40) }
            ptz.trackDriveRaw(pan: Int(pan), tilt: Int(tilt), camera: s.camera)
        }
        if zoom != s.sentZoom {
            s.sentZoom = zoom
            ptz.trackZoom(zoom, camera: s.camera)
        }
    }

    /// Stops a camera whose picture has stopped coming in, so it never drifts on old frames.
    private func tick() {
        let now = Date()
        for id in sessions.keys { poll(id) }
        for (id, var s) in sessions where now.timeIntervalSince(s.lastFrame) > 0.6 && (s.sentPan != 0 || s.sentTilt != 0 || s.sentZoom != 0) {
            hold(&s)
            s.phase = .searching
            sessions[id] = s
        }
        let expired = sessions.values.filter { $0.target == nil && now.timeIntervalSince($0.started) > 4 }
        for s in expired {
            finish(s.camera, "No person found. Tracking stopped.")
            stop(s.camera)
        }
    }

    /// Reads where the camera really is: its angle of view, and how fast it's really turning
    /// compared with the speed it was asked for.
    private func poll(_ id: UUID) {
        guard var s = sessions[id], !s.polling else { return }
        s.polling = true
        sessions[id] = s
        let token = s.token
        ptz.readPosition(camera: id) { [weak self] pos in
            guard let self, var s = self.sessions[id], s.token == token else { return }
            s.polling = false
            if let pos {
                let now = Date()
                if pos.zoom > 50 { s.fov = Double(pos.zoom) / 100 }
                let pan = Double(pos.pan) / 100, tilt = Double(pos.tilt) / 100
                if let last = s.lastPos {
                    let dt = now.timeIntervalSince(last.at)
                    // Learn only from a steady speed held long enough for the camera to reach it.
                    if dt > 0.1 {
                        // Degrees it was asked to turn over that time (the camera reacts about
                        // 0.15 s late), against how far it really turned. Learn only from
                        // clear moves in one direction.
                        func asked(_ axis: (Double, Double) -> Double) -> Double {
                            let from = last.at.addingTimeInterval(-0.15), to = now.addingTimeInterval(-0.15)
                            var total = 0.0
                            let log = s.sentLog
                            for (i, e) in log.enumerated() {
                                let start = max(from, e.at)
                                let end = min(to, i + 1 < log.count ? log[i + 1].at : to)
                                if end > start { total += axis(e.pan, e.tilt) / 100 * end.timeIntervalSince(start) }
                            }
                            return total
                        }
                        func learn(_ g: inout Double, _ moved: Double, _ want: Double) {
                            guard abs(want) > 0.3, moved * want > 0 else { return }
                            let seen = abs(moved) / abs(want)
                            if seen.isFinite { g += (min(1.5, max(0.05, seen)) - g) * 0.35 }
                        }
                        learn(&s.gainPan, pan - last.pan, asked { p, _ in p })
                        learn(&s.gainTilt, tilt - last.tilt, asked { _, t in t })
                    }
                }
                s.lastPos = (pan, tilt, now)
                s.polls.append((now, pan, tilt))
                if s.polls.count > 16 { s.polls.removeFirst(s.polls.count - 16) }
            }
            self.sessions[id] = s
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

