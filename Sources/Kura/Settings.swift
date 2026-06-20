import Foundation

struct RegisteredApp: Codable, Identifiable, Equatable, Hashable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String
}

final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("KuraSettingsDidChange")

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
        let before = registeredApps.count
        registeredApps.removeAll { $0 == app }
        guard registeredApps.count != before else { return }
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
