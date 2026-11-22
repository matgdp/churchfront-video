import Combine
import CoreGraphics
import Foundation

/// FFmpeg demuxes the camera's RTSP stream and hands the tracker bounded-size BGRA frames.
final class RTSPFeed: ObservableObject {
    static let width = 640
    static let height = 360
    static let filter = "fps=10,scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2,setsar=1"

    let frames = PassthroughSubject<CGImage, Never>()
    @Published private(set) var image: CGImage?
    @Published private(set) var status = "Disconnected"
    @Published private(set) var live = false

    private var process: Process?
    private var watchdog: Timer?
    private var generation = UUID()
    private var lastFrame = Date()

    func start(url: URL) {
        stop()
        let executable = ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
        guard let executable else {
            status = "FFmpeg required. Install it with brew install ffmpeg."
            return
        }

        let token = generation
        let child = Process()
        let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-rtsp_transport", "tcp",
                           "-timeout", "5000000", "-i", url.absoluteString, "-an", "-sn", "-dn",
                           "-vf", Self.filter, "-c:v", "rawvideo", "-threads", "1",
                           "-pix_fmt", "bgra", "-f", "rawvideo", "pipe:1"]
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            status = "Could not start FFmpeg"
            return
        }
        process = child
        status = "Waiting for RTSP video"
        lastFrame = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let limit: TimeInterval = self.live ? 1.5 : 10
            guard Date().timeIntervalSince(self.lastFrame) > limit else { return }
            self.stop()
            self.status = "No RTSP video. Check the camera’s stream settings and path."
        }

        let input = pipe.fileHandleForReading
        let frameSize = Self.width * Self.height * 4
        let pending = DispatchSemaphore(value: 1)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { try? input.close() }
            var frame = Data()
            while true {
                guard let chunk = try? input.read(upToCount: frameSize - frame.count), !chunk.isEmpty else { break }
                frame.append(chunk)
                guard frame.count == frameSize else { continue }
                if pending.wait(timeout: .now()) == .success {
                    let data = frame
                    DispatchQueue.main.async { [weak self] in
                        defer { pending.signal() }
                        guard let self, self.generation == token, let image = Self.makeImage(data) else { return }
                        self.lastFrame = Date()
                        if !self.live { self.live = true; self.status = "RTSP video connected" }
                        self.image = image
                        self.frames.send(image)
                    }
                }
                frame.removeAll(keepingCapacity: true)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.generation else { return }
                self.stop()
                self.status = "RTSP stream ended. Check the camera’s stream settings and path."
            }
        }
    }

    func stop() {
        generation = UUID()
        watchdog?.invalidate()
        watchdog = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        live = false
        image = nil
        status = "Disconnected"
    }

    private static func makeImage(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
