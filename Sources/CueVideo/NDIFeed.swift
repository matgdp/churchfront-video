import SwiftUI
import CoreGraphics
import NDIBridge

/// A small live picture from an NDI source, such as CueScreens' graphics or its lower thirds.
/// It asks the sender for NDI's low-bandwidth preview stream (about 640 wide), so watching it
/// costs little network or processor time, and keeps the alpha channel when the source sends
/// one, so a lower third can be laid over a camera picture.
final class NDIFeed: ObservableObject, @unchecked Sendable {
    @Published private(set) var image: CGImage?
    @Published private(set) var live = false
    @Published private(set) var hasAlpha = false
    /// The frames' pixel size and the shape the sender says to show them at, for Status.
    private(set) var shape = ""

    let source: String
    private let lock = NSLock()
    private var generation = 0

    init(source: String) { self.source = source }

    func start() {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        let t = Thread { [weak self] in self?.receive(gen) }
        t.name = "NDI preview"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func stop() {
        lock.lock(); generation += 1; lock.unlock()
        DispatchQueue.main.async { self.live = false }
    }

    private func current(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == gen }

    private func receive(_ gen: Int) {
        // If the UI is busy, discard previews instead of queuing copies of old frames.
        let frameSlot = DispatchSemaphore(value: 1)
        // The runtime may be missing, or the source not on the network yet: keep trying.
        while current(gen) {
            let opened = Self.resolve(source, wait: 800)
            guard let recv = opened.withCString({ ndi_recv_open_bw($0, true) }) else {
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            var lastShown = Date.distantPast, lastFrame = Date(), lastLook = Date()
            while current(gen) {
                var data: UnsafePointer<UInt8>?
                var w: Int32 = 0, h: Int32 = 0, stride: Int32 = 0
                var alpha = false
                var frame: UnsafeMutableRawPointer?
                guard ndi_recv_frame_alpha(recv, 250, &data, &w, &h, &stride, &alpha, &frame), let data else {
                    if Date().timeIntervalSince(lastFrame) > 2 { DispatchQueue.main.async { if self.current(gen) { self.live = false } } }
                    // No picture for a while: the sender may be back under another computer
                    // name (see resolve). If so, close this and open that.
                    if Date().timeIntervalSince(lastFrame) > 4, Date().timeIntervalSince(lastLook) > 3 {
                        lastLook = Date()
                        if Self.resolve(source, wait: 0) != opened { break }
                    }
                    continue
                }
                lastFrame = Date()
                // A preview doesn't need every frame: about 20 a second is plenty.
                if lastFrame.timeIntervalSince(lastShown) >= 0.05, frameSlot.wait(timeout: .now()) == .success {
                    lastShown = lastFrame
                    let aspect = Double(ndi_frame_aspect(frame))
                    let img = Self.image(data, Int(w), Int(h), Int(stride), alpha).map { Self.squared($0, aspect: aspect) }
                    let shape = "\(w)x\(h)" + (aspect > 0 ? String(format: ", shown %.2f:1", aspect) : "")
                    DispatchQueue.main.async { [alpha] in
                        defer { frameSlot.signal() }
                        guard self.current(gen) else { return }
                        self.image = img
                        if self.shape != shape { self.shape = shape }
                        if !self.live { self.live = true }
                        if self.hasAlpha != alpha { self.hasAlpha = alpha }
                    }
                }
                ndi_recv_release(recv, frame)
            }
            ndi_recv_close(recv)
        }
    }

    /// The sender to open for a saved source name. A source is named "COMPUTER (Channel)",
    /// and the computer half isn't stable: the same Mac can announce itself by its sharing
    /// name one day and its network name the next ("PRODUCTN01SMINI", "PRODUCTION-01S-MAC-
    /// MINI.LOCAL"). So when the saved name isn't on the network but exactly one sender has
    /// the same channel, that's the one. Otherwise the saved name, as it is.
    static func resolve(_ wanted: String, wait: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256 * 64)
        let n = Int(ndi_sources(&buf, 64, wait))
        let names = (0..<n).map { i in buf.withUnsafeBufferPointer { String(cString: $0.baseAddress! + i * 256) } }
        return match(wanted, in: names)
    }

    static func match(_ wanted: String, in names: [String]) -> String {
        if names.contains(wanted) { return wanted }
        guard let ch = channel(wanted) else { return wanted }
        let same = names.filter { channel($0) == ch }
        return same.count == 1 ? same[0] : wanted
    }

    /// "COMPUTER (Channel)" gives "Channel".
    static func channel(_ full: String) -> String? {
        guard let open = full.firstIndex(of: "("), full.hasSuffix(")") else { return nil }
        return String(full[full.index(after: open)..<full.index(before: full.endIndex)])
    }

    /// Some senders' preview streams have pixels that aren't square (a 16:9 picture sent as
    /// 720x480, say) and state the shape to show it at. Stretch those to that shape, so the
    /// picture looks right everywhere and people in it aren't squashed for auto tracking.
    static func squared(_ img: CGImage, aspect: Double) -> CGImage {
        guard aspect > 0.2, aspect < 5, img.height > 0 else { return img }
        let have = Double(img.width) / Double(img.height)
        guard abs(have - aspect) / aspect > 0.02 else { return img }
        let w = Int((Double(img.height) * aspect).rounded()), h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return img }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    /// NDI's BGRA is straight (not premultiplied) alpha; BGRX has none.
    static func image(_ src: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ stride: Int, _ alpha: Bool) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        let data = Data(bytes: src, count: stride * h)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.rawValue
            | (alpha ? CGImageAlphaInfo.first.rawValue : CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// One receiver per NDI source, shared by everything showing it, running only while shown.
final class NDIFeedHub {
    static let shared = NDIFeedHub()
    private var feeds: [String: NDIFeed] = [:]
    private var users: [String: Int] = [:]

    func feed(_ source: String) -> NDIFeed {
        if let f = feeds[source] { return f }
        let f = NDIFeed(source: source)
        feeds[source] = f
        return f
    }

    func retain(_ source: String) {
        users[source, default: 0] += 1
        if users[source] == 1 { feed(source).start() }
    }

    func release(_ source: String) {
        guard let n = users[source] else { return }
        if n <= 1 { users[source] = nil; feeds[source]?.stop() } else { users[source] = n - 1 }
    }

    /// For status: whether a source's picture is coming in (nil when nothing is showing it).
    func isLive(_ source: String) -> Bool? { users[source] == nil ? nil : feeds[source]?.live }
    func shape(_ source: String) -> String? { feeds[source].flatMap { $0.shape.isEmpty ? nil : $0.shape } }
}

/// An NDI source's picture, fitted to its frame. With `overlay`, nothing is drawn behind it
/// and no waiting message shows, so it can sit on top of another picture.
struct NDIVideo: View {
    let source: String
    var overlay = false
    @ObservedObject private var feed: NDIFeed

    init(source: String, overlay: Bool = false) {
        self.source = source
        self.overlay = overlay
        feed = NDIFeedHub.shared.feed(source)
    }

    var body: some View {
        ZStack {
            if !overlay { Color.black }
            if let img = feed.image, !overlay || feed.live {
                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
            }
            if !overlay, !feed.live {
                VStack(spacing: T.s1) {
                    ProgressView().controlSize(.small)
                    Text(feed.image == nil ? "Waiting for \(NDIMonitor.shortName(source))" : "Picture stopped")
                        .font(.sans(11)).foregroundStyle(T.inkMuted).lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(T.s2)
                .background(RoundedRectangle(cornerRadius: T.rMD).fill(Color.black.opacity(0.6)))
            }
        }
        .allowsHitTesting(false)
        .onAppear { NDIFeedHub.shared.retain(source) }
        .onDisappear { NDIFeedHub.shared.release(source) }
    }
}
