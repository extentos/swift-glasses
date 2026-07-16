import Foundation

// Persistent device-install identifier for the Track B+ pending socket.
// Mirrors Android's DeviceInstallStore (file-backed UUID under filesDir);
// iOS uses UserDefaults.standard which has the same "wiped on uninstall"
// semantics — Apple guarantees app preferences are removed alongside the
// app bundle. See ios-auto-bind-handoff.md § deviceInstallId persistence.
//
// The id is opaque to the dev. Format: "di_" + 24 hex chars from UUIDv4.

enum DeviceInstallStore {
    private static let key = "com.extentos.deviceInstallId"

    static func resolve() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let generated = "di_" + String(raw.prefix(24))
        defaults.set(generated, forKey: key)
        return generated
    }
}
