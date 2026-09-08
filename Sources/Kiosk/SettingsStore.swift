import AppKit
import KioskCore

@MainActor
final class SettingsStore {
    private let defaults = UserDefaults.standard
    private(set) var configuration = KioskConfiguration()
    private(set) var credential: OperatorCredential?
    private(set) var loadError: String?

    init() {
        do {
            if let url = Bundle.main.url(forResource: "Defaults", withExtension: "plist", subdirectory: "Model") {
                configuration = try PropertyListDecoder().decode(KioskConfiguration.self, from: Data(contentsOf: url))
            }
            if let data = defaults.data(forKey: "configuration") {
                configuration = try JSONDecoder().decode(KioskConfiguration.self, from: data)
            }
            if let data = defaults.data(forKey: "operatorCredential") {
                credential = try JSONDecoder().decode(OperatorCredential.self, from: data)
            }
        } catch {
            // Never auto-start with a silently discarded credential or damaged configuration.
            loadError = "Saved settings could not be read. Review and save settings before starting. \(error.localizedDescription)"
            configuration.startAutomatically = false
        }
    }

    func save(_ value: KioskConfiguration, newPasscode: String, removePasscode: Bool) throws {
        let validated = try value.validated()
        var updatedCredential = credential
        if removePasscode { updatedCredential = nil }
        if !newPasscode.isEmpty { updatedCredential = try OperatorCredential(passcode: newPasscode) }
        let configurationData = try JSONEncoder().encode(validated)
        let credentialData = try updatedCredential.map { try JSONEncoder().encode($0) }
        defaults.set(configurationData, forKey: "configuration")
        defaults.set(credentialData, forKey: "operatorCredential")
        configuration = validated
        credential = updatedCredential
        loadError = nil
    }
}
