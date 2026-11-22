import AppKit
import Combine
import CameraControl
import SwiftUI

final class CameraSession {
    static let shared = CameraSession()
    let ptz = PTZController(load: false)
    let feed = RTSPFeed()
    lazy var tracker = AutoTracker(ptz: ptz)

    func stopMotion() {
        tracker.stopAll()
        ptz.stopAllManual()
    }

    func disconnect() {
        stopMotion()
        feed.stop()
        ptz.cameras = []
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CameraSession.shared.stopMotion()
        CameraSession.shared.feed.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationDidResignActive(_ notification: Notification) {
        CameraSession.shared.ptz.stopAllManual()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CameraTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Camera Tracker", id: "tracker") {
            TrackerView(session: .shared)
                .frame(minWidth: 680, minHeight: 550)
        }
        .defaultSize(width: 840, height: 660)
    }
}

struct TrackerView: View {
    let session: CameraSession
    @ObservedObject var ptz: PTZController
    @ObservedObject var feed: RTSPFeed
    @ObservedObject var tracker: AutoTracker
    @AppStorage("cameraHost") private var host = ""
    @AppStorage("viscaPort") private var controlPort = "5678"
    @AppStorage("rtspPort") private var rtspPort = "554"
    @AppStorage("rtspPath") private var path = "/2"
    @State private var shot = ShotSize.waist
    @State private var autoZoom = false
    @State private var message: String?

    init(session: CameraSession) {
        self.session = session
        ptz = session.ptz
        feed = session.feed
        tracker = session.tracker
    }

    private var camera: PTZCamera? { ptz.current }
    private var tracking: AutoTracker.Session? { camera.flatMap { tracker.sessions[$0.id] } }
    private var answering: Bool { camera.map { ptz.online.contains($0.id) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Camera IP", text: $host).accessibilityLabel("Camera IP").frame(width: 160)
                TextField("VISCA port", text: $controlPort).accessibilityLabel("VISCA port").frame(width: 64)
                TextField("RTSP port", text: $rtspPort).accessibilityLabel("RTSP port").frame(width: 64)
                TextField("RTSP path", text: $path).accessibilityLabel("RTSP path").frame(width: 85)
                Button("Connect", action: connect).disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Disconnect") { session.disconnect(); message = nil }.disabled(camera == nil)
                Spacer()
            }
            HStack(spacing: 20) {
                Label(answering ? "VISCA TCP connected" : camera == nil ? "VISCA disconnected" : "Waiting for VISCA TCP",
                      systemImage: answering ? "checkmark.circle" : "circle")
                Text(feed.status)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            GeometryReader { proxy in
                let width = min(proxy.size.width, proxy.size.height * 16 / 9)
                let height = width * 9 / 16
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.black)
                    if let image = feed.image {
                        Image(decorative: image, scale: 1).resizable()
                    } else {
                        Text("Camera preview").foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let box = tracking?.target?.box {
                        Rectangle().stroke(.green, lineWidth: 2)
                            .frame(width: box.width * width, height: box.height * height)
                            .offset(x: box.minX * width, y: box.minY * height)
                    }
                }
                .frame(width: width, height: height)
                .clipped()
                .contentShape(Rectangle())
                .help("Click a person to follow them")
                .onTapGesture(coordinateSpace: .local) { point in
                    guard width > 0, height > 0 else { return }
                    follow(at: CGPoint(x: point.x / width, y: point.y / height))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Button("Start Tracking") { follow(at: nil) }.keyboardShortcut(.defaultAction)
                    .disabled(!answering || !feed.live)
                Button("Stop") { session.stopMotion(); message = nil }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!answering && tracking == nil)
                Picker("Framing", selection: $shot) {
                    ForEach(ShotSize.allCases) { size in Text(size.name).tag(size) }
                }
                .frame(width: 165)
                .onChange(of: shot) { _, size in
                    if let camera { tracker.setSize(camera.id, size) }
                }
                Toggle("Auto zoom", isOn: $autoZoom)
                    .onChange(of: autoZoom) { _, value in tracker.config.trackZoom = value }
                Spacer()
                Text(message ?? trackingStatus).font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("Manual").foregroundStyle(.secondary)
                move("Left", "arrow.left", -0.35, 0)
                move("Up", "arrow.up", 0, 0.35)
                move("Down", "arrow.down", 0, -0.35)
                move("Right", "arrow.right", 0.35, 0)
                HoldControl(title: "Zoom out", icon: "minus.magnifyingglass") { ptz.zoom(-0.3) } stop: { ptz.zoom(0) }
                HoldControl(title: "Zoom in", icon: "plus.magnifyingglass") { ptz.zoom(0.3) } stop: { ptz.zoom(0) }
            }
            .disabled(!answering)
        }
        .padding(20)
        .onChange(of: feed.live) { _, live in if !live { tracker.stopAll() } }
        .onChange(of: answering) { _, online in if !online { session.stopMotion() } }
    }

    private var trackingStatus: String {
        switch tracking?.phase {
        case .starting: return "Looking for a person"
        case .following: return "Tracking"
        case .searching, .lost: return "Subject lost — holding shot"
        case nil: return "Tracking off"
        }
    }

    private func connect() {
        let address = host.trimmingCharacters(in: .whitespaces)
        let streamPath = path.trimmingCharacters(in: .whitespaces)
        guard let visca = UInt16(controlPort), visca > 0, let rtsp = UInt16(rtspPort), rtsp > 0,
              streamPath.hasPrefix("/"),
              address.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
            message = "Enter a camera IP, valid ports, and a path such as /2."
            return
        }
        var stream = URLComponents()
        stream.scheme = "rtsp"
        stream.host = address
        stream.port = Int(rtsp)
        stream.path = streamPath
        guard let url = stream.url else { return }
        session.disconnect()
        message = nil
        var camera = PTZCamera()
        camera.host = address
        camera.proto = .rawTCP
        camera.port = visca
        ptz.cameras = [camera]
        ptz.selected = camera.id
        feed.start(url: url)
    }

    private func follow(at point: CGPoint?) {
        guard let camera, answering, feed.live else { return }
        tracker.start(camera, frames: feed.frames.eraseToAnyPublisher(), at: point, size: shot) { result in
            message = result
        }
        message = nil
    }

    private func move(_ title: String, _ icon: String, _ x: Double, _ y: Double) -> some View {
        HoldControl(title: title, icon: icon) { ptz.drive(x: x, y: y) } stop: { ptz.stopDrive() }
    }
}

private struct HoldControl: View {
    let title: String
    let icon: String
    let start: () -> Void
    let stop: () -> Void
    @GestureState private var held = false

    var body: some View {
        Image(systemName: icon)
            .frame(width: 38, height: 30)
            .background(held ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).updating($held) { _, value, _ in value = true })
            .onChange(of: held) { _, down in if down { start() } else { stop() } }
            .help("Hold to \(title.lowercased())")
            .accessibilityLabel(title)
    }
}
