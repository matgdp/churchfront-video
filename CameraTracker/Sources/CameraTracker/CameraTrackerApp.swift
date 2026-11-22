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
    @AppStorage("savedCameras") private var cameraData = Data()
    @AppStorage("selectedCameraID") private var selectedCameraID = ""
    @State private var editingCamera: CameraProfile?
    @State private var connectedProfileID: UUID?
    @State private var shot = ShotSize.waist
    @State private var autoZoom = false
    @State private var message: String?

    init(session: CameraSession) {
        self.session = session
        ptz = session.ptz
        feed = session.feed
        tracker = session.tracker
    }

    private var savedCameras: [CameraProfile] {
        (try? JSONDecoder().decode([CameraProfile].self, from: cameraData)) ?? []
    }

    private var selectedCamera: CameraProfile? {
        savedCameras.first { $0.id.uuidString == selectedCameraID }
    }

    private var camera: PTZCamera? { ptz.current }
    private var tracking: AutoTracker.Session? { camera.flatMap { tracker.sessions[$0.id] } }
    private var answering: Bool { camera.map { ptz.online.contains($0.id) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Camera", selection: $selectedCameraID) {
                    if selectedCamera == nil { Text("Select a camera").tag("") }
                    ForEach(savedCameras) { profile in
                        Text("\(profile.name) (\(profile.host))").tag(profile.id.uuidString)
                    }
                }
                .frame(maxWidth: 300)
                .disabled(savedCameras.isEmpty)
                Button("Add Camera…") { editingCamera = CameraProfile() }
                Button("Edit…") { editingCamera = selectedCamera }.disabled(selectedCamera == nil)
                Button("Connect") {
                    if let selectedCamera { connect(selectedCamera) }
                }
                .disabled(selectedCamera == nil || camera != nil)
                Button("Disconnect", action: disconnect).disabled(camera == nil)
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
                    if tracking?.phase == .following, let box = tracking?.target?.box {
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
                    .onChange(of: autoZoom) { _, value in tracker.autoZoom = value }
                Spacer()
                Text(message ?? trackingStatus).font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("Manual").foregroundStyle(.secondary)
                move("Left", "arrow.left", -0.35, 0)
                move("Up", "arrow.up", 0, 0.35)
                move("Down", "arrow.down", 0, -0.35)
                move("Right", "arrow.right", 0.35, 0)
                zoom("Zoom out", "minus.magnifyingglass", -0.3)
                zoom("Zoom in", "plus.magnifyingglass", 0.3)
            }
            .disabled(!answering)
            .id(camera?.id)
        }
        .padding(20)
        .onAppear(perform: migrateLegacyCamera)
        .onChange(of: selectedCameraID) { _, _ in
            guard camera != nil, let selectedCamera, connectedProfileID != selectedCamera.id else { return }
            connect(selectedCamera)
        }
        .sheet(item: $editingCamera) { profile in
            CameraProfileEditor(
                profile: profile,
                existing: savedCameras.contains { $0.id == profile.id },
                save: saveCamera,
                remove: removeCamera
            )
        }
        .onChange(of: feed.live) { _, live in if !live { tracker.stopAll() } }
        .onChange(of: answering) { _, online in if !online { session.stopMotion() } }
    }

    private var trackingStatus: String {
        switch tracking?.phase {
        case .starting: return "Looking for a person"
        case .following: return "Tracking"
        case .searching: return "Looking for the selected person"
        case .lost: return "Subject lost. Click the person again."
        case nil: return "Tracking off"
        }
    }

    private func migrateLegacyCamera() {
        guard cameraData.isEmpty else {
            if selectedCamera == nil { selectedCameraID = savedCameras.first?.id.uuidString ?? "" }
            return
        }
        let defaults = UserDefaults.standard
        var profile = CameraProfile()
        profile.name = "Camera 1"
        profile.host = defaults.string(forKey: "cameraHost") ?? ""
        profile.viscaPort = defaults.string(forKey: "viscaPort") ?? "5678"
        profile.rtspPort = defaults.string(forKey: "rtspPort") ?? "554"
        profile.path = defaults.string(forKey: "rtspPath") ?? "/2"
        if let profile = profile.validated {
            saveCamera(profile)
        } else if profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            persist([])
        } else {
            editingCamera = profile
        }
    }

    private func persist(_ profiles: [CameraProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        cameraData = data
    }

    private func saveCamera(_ profile: CameraProfile) {
        var profiles = savedCameras
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persist(profiles)
        selectedCameraID = profile.id.uuidString
        if camera != nil { connect(profile) }
    }

    private func removeCamera(_ profile: CameraProfile) {
        let profiles = savedCameras.filter { $0.id != profile.id }
        if connectedProfileID == profile.id { disconnect() }
        persist(profiles)
        if selectedCameraID == profile.id.uuidString {
            selectedCameraID = profiles.first?.id.uuidString ?? ""
        }
    }

    private func connect(_ profile: CameraProfile) {
        guard let url = profile.streamURL, let port = UInt16(profile.viscaPort) else { return }
        disconnect()
        connectedProfileID = profile.id
        var camera = PTZCamera()
        camera.host = profile.host
        camera.proto = .rawTCP
        camera.port = port
        ptz.cameras = [camera]
        ptz.selected = camera.id
        feed.start(url: url)
    }

    private func disconnect() {
        session.disconnect()
        connectedProfileID = nil
        message = nil
    }

    private func follow(at point: CGPoint?) {
        guard let camera, answering, feed.live else { return }
        tracker.start(camera, frames: feed.frames.eraseToAnyPublisher(), at: point, size: shot) { result in
            message = result
        }
        message = nil
    }

    private func move(_ title: String, _ icon: String, _ x: Double, _ y: Double) -> some View {
        let id = camera?.id
        return HoldControl(title: title, icon: icon) {
            if let id { ptz.drive(x: x, y: y, camera: id) }
        } stop: {
            if let id { ptz.stopDrive(camera: id) }
        }
    }

    private func zoom(_ title: String, _ icon: String, _ speed: Double) -> some View {
        let id = camera?.id
        return HoldControl(title: title, icon: icon) {
            if let id { ptz.zoom(speed, camera: id) }
        } stop: {
            if let id { ptz.zoom(0, camera: id) }
        }
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
