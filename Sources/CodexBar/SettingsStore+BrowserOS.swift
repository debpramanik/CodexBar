import CodexBarCore
import Foundation

extension SettingsStore {
    static let browserOSDefaultEndpoint = "http://127.0.0.1:9001/mcp"

    var browserOSEnabled: Bool {
        get { self.userDefaults.object(forKey: "browserOSEnabled") as? Bool ?? false }
        set {
            self.userDefaults.set(newValue, forKey: "browserOSEnabled")
        }
    }

    var browserOSEndpoint: String {
        get {
            let stored = self.userDefaults.string(forKey: "browserOSEndpoint") ?? ""
            return stored.isEmpty ? Self.browserOSDefaultEndpoint : stored
        }
        set {
            self.userDefaults.set(newValue, forKey: "browserOSEndpoint")
            // Update the provider endpoint in real-time
            BrowserOSCookieProvider.endpoint = newValue.isEmpty ? Self.browserOSDefaultEndpoint : newValue
        }
    }
}
