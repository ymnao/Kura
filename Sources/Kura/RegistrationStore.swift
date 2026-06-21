import AppKit

struct RegisteredApp: Codable, Hashable {
    let bundleIdentifier: String
    let name: String

    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }
}

final class RegistrationStore {
    static let shared = RegistrationStore()
    static let didChange = Notification.Name("KuraRegistrationDidChange")

    private let storageKey = "registeredApps"
    private let defaults = UserDefaults.standard

    private(set) var registeredApps: [RegisteredApp]

    private init() {
        if let data = defaults.data(forKey: storageKey),
           let apps = try? JSONDecoder().decode([RegisteredApp].self, from: data) {
            registeredApps = apps
        } else {
            registeredApps = []
        }
    }

    func add(_ app: RegisteredApp) {
        guard !registeredApps.contains(app) else { return }
        registeredApps.append(app)
        persist()
        notifyChange()
    }

    func remove(_ app: RegisteredApp) {
        guard let idx = registeredApps.firstIndex(of: app) else { return }
        registeredApps.remove(at: idx)
        persist()
        notifyChange()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(registeredApps) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
