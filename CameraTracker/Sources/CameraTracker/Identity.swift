// Adapted from Churchfront Video (Copyright 2026 Churchfront LLC) for the standalone Camera Tracker.
import Foundation
import Vision
import CoreGraphics

/// What a person looks like in a picture, as a fingerprint of their clothes, build and
/// colouring (Apple's Vision framework, worked out on this Mac). Two pictures of the same
/// person in the same outfit give fingerprints that sit close together; two different people
/// sit farther apart. It is not face recognition and holds nothing that names anyone: it
/// tells people on the stage apart for one service.
///
/// Measured on the booth's cameras: the same crop moved or resized a little scores about
/// 0.2 to 0.3, different things 0.7 to 1.1.
struct Appearance {
    let print: VNFeaturePrintObservation

    /// How different two looks are: near 0 is the same, about 1 is someone else.
    func distance(to other: Appearance) -> Double? {
        var d: Float = 0
        do { try print.computeDistance(&d, to: other.print) } catch { return nil }
        return Double(d)
    }

    /// The closest this look comes to any of several pictures of one person.
    func distance(to gallery: [Appearance]) -> Double? { gallery.compactMap { distance(to: $0) }.min() }

    /// The look of whoever is inside `box` (0 to 1, origin top left) in a picture. Nil when
    /// they're too small to tell.
    static func of(_ img: CGImage, box: CGRect) -> Appearance? {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        // The middle of the box: arms held out reach into the background on both sides.
        let core = box.insetBy(dx: box.width * 0.1, dy: 0)
        let r = CGRect(x: core.minX * w, y: core.minY * h, width: core.width * w, height: core.height * h)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard r.width >= 20, r.height >= 24, let crop = img.cropping(to: r) else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        req.revision = VNGenerateImageFeaturePrintRequestRevision2  // distances only compare within one revision
        do { try VNImageRequestHandler(cgImage: crop).perform([req]) } catch { return nil }
        return (req.results?.first as? VNFeaturePrintObservation).map(Appearance.init)
    }
}

/// Deciding which person in a new frame is the one being followed, from where everyone is
/// and what they look like. Kept free of pictures and cameras so it can be tested on its own.
enum IdentityMatch {
    /// One person in the frame: how far they are from where the followed person was (as a
    /// share of the frame), and how different they look from them (nil when it can't be told).
    struct Candidate {
        var position: Double
        var appearance: Double?
    }

    /// What's been learned while following: how much the followed person's own look varies
    /// from frame to frame, and how different the other people near them look.
    struct Model {
        var own: Double?
        var others: Double?

        /// The most different someone can look and still be taken for the followed person
        /// when there's no one to compare them with. Halfway between "them" and "the others"
        /// once both are known. Before that it leans generous, because wrongly refusing the
        /// right person stops the camera following at all.
        var limit: Double? {
            guard let own else { return nil }
            if let others, others > own { return max(0.45, own + (others - own) * 0.5) }
            return max(0.6, own * 3)
        }
    }

    enum Choice: Equatable {
        /// Follow this person. `sure` when their look confirms it (safe to learn from).
        case take(Int, sure: Bool)
        /// None of them is clearly the one: hold the shot and keep looking.
        case wait
    }

    /// - reach: how far from their last place the followed person could be by now.
    /// - gone: seconds since they were last seen for certain.
    static func choose(_ people: [Candidate], reach: Double, gone: Double, model: Model) -> Choice {
        let near = people.indices.filter { people[$0].position < reach }
        guard let nearest = near.min(by: { people[$0].position < people[$1].position }) else { return .wait }
        let known = near.filter { people[$0].appearance != nil }
            .sorted { people[$0].appearance! < people[$1].appearance! }
        // Seen a moment ago: where they were still counts for a lot. After a gap it doesn't.
        let continuous = gone < 0.7

        if known.count >= 2 {
            // Two or more people it could be (they crossed, or stand together): the one who
            // looks most like the followed person, if that's clear. This needs no fixed
            // number, only that one of them is a distinctly better fit than the next.
            let best = people[known[0]].appearance!, next = people[known[1]].appearance!
            let clear = best < next * 0.8 && (model.limit.map { best < $0 * 1.3 } ?? true)
            if clear { return .take(known[0], sure: true) }
            return continuous ? .take(nearest, sure: false) : .wait
        }
        if known.count == 1, near.count == 1, let limit = model.limit {
            // One person there. If they were lost for a while, they have to look right;
            // otherwise the camera would pick up whoever walked into the gap.
            if people[known[0]].appearance! <= limit { return .take(nearest, sure: true) }
            return continuous ? .take(nearest, sure: false) : .wait
        }
        // Nothing to tell them apart by (too small, or nothing learned yet): the nearest.
        return .take(nearest, sure: false)
    }

    /// Finding a named person (from the stage scan) among everyone in the frame: the best
    /// fit, if they're a clearly better fit than the next person, or the only one there.
    static func find(_ looks: [Double?]) -> Int? {
        let known = looks.indices.filter { looks[$0] != nil }.sorted { looks[$0]! < looks[$1]! }
        guard let best = known.first else { return looks.count == 1 ? 0 : nil }
        if known.count == 1 { return looks.count == 1 || looks[best]! < 0.6 ? best : nil }
        return looks[best]! < looks[known[1]]! * 0.85 ? best : nil
    }
}

