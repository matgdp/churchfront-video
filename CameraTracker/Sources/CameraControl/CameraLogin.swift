import Foundation
import Security

/// The cameras' admin login, kept in this Mac's Keychain (never in the config file).
/// Only needed for changing presets stored on the cameras themselves; everyday control
/// and CueVideo's own shots work without it. One login is used for every Canon camera.
public enum CameraLogin {
    private static let service = "CueVideo camera admin login"
    private static let account = "canon"
    /// The user name alone, kept in the app's preferences so Setup can show it without
    /// opening the Keychain. It isn't a secret; the password never leaves the Keychain.
    private static let userKey = "cameraLoginUser"

    public struct Credential { public let user: String; public let password: String }

    public static func load() -> Credential? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8), let nl = s.firstIndex(of: "\n") else { return nil }
        return Credential(user: String(s[..<nl]), password: String(s[s.index(after: nl)...]))
    }

    /// Saves (or replaces) the login. Returns false if the Keychain refused.
    @discardableResult
    public static func save(user: String, password: String) -> Bool {
        clear()
        UserDefaults.standard.set(user, forKey: userKey)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecAttrLabel as String: service,
                                   kSecValueData as String: Data("\(user)\n\(password)".utf8)]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func clear() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        UserDefaults.standard.removeObject(forKey: userKey)
    }

    /// Whether a login is saved. Asks the Keychain only whether the item is there, not for
    /// what's in it, so macOS never asks for the Mac's password to answer this.
    public static var isSaved: Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    /// The saved user name, for showing in Setup (the password is never shown). Read from
    /// the app's preferences, not the Keychain: opening the Keychain item makes macOS ask
    /// for the Mac's password whenever the app has been rebuilt, and Setup redraws often.
    /// Nil for a login saved before this was kept (the login still works).
    public static var savedUser: String? { UserDefaults.standard.string(forKey: userKey) }
}

/// Answers the camera's login challenge (Basic or Digest) once with the saved login.
final class LoginDelegate: NSObject, URLSessionTaskDelegate {
    let credential: URLCredential
    init(_ c: CameraLogin.Credential) { credential = URLCredential(user: c.user, password: c.password, persistence: .forSession) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let m = challenge.protectionSpace.authenticationMethod
        if (m == NSURLAuthenticationMethodHTTPBasic || m == NSURLAuthenticationMethodHTTPDigest) && challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, credential)
        } else if m == NSURLAuthenticationMethodHTTPBasic || m == NSURLAuthenticationMethodHTTPDigest {
            completionHandler(.cancelAuthenticationChallenge, nil)  // wrong login: stop rather than loop
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
