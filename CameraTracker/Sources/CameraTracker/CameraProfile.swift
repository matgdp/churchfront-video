import Foundation
import SwiftUI

struct CameraProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var host = ""
    var viscaPort = "5678"
    var rtspPort = "554"
    var path = "/2"

    var validated: Self? {
        var profile = self
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.viscaPort = viscaPort.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.rtspPort = rtspPort.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty,
              profile.host.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil,
              let port = UInt16(profile.viscaPort), port > 0, profile.streamURL != nil else { return nil }
        return profile
    }

    var streamURL: URL? {
        guard let port = UInt16(rtspPort), port > 0, path.hasPrefix("/") else { return nil }
        var stream = URLComponents()
        stream.scheme = "rtsp"
        stream.host = host
        stream.port = Int(port)
        stream.path = path
        return stream.url
    }
}

struct CameraProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: CameraProfile
    let existing: Bool
    let save: (CameraProfile) -> Void
    let remove: (CameraProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing ? "Edit Camera" : "Add Camera").font(.headline)
            Form {
                TextField("Name", text: $profile.name)
                TextField("IP address", text: $profile.host)
                TextField("VISCA port", text: $profile.viscaPort)
                TextField("RTSP port", text: $profile.rtspPort)
                TextField("RTSP path", text: $profile.path)
            }
            HStack {
                if existing {
                    Button("Remove Camera", role: .destructive) {
                        remove(profile)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let valid = profile.validated {
                        save(valid)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.validated == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
