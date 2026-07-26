import Foundation

struct SenderConfiguration: Equatable {
    var receiverServiceName: String
    var pairingCode: String
    var quality: StreamQuality

    var isReady: Bool {
        !receiverServiceName.isEmpty && PairingSecret.isValid(pairingCode)
    }
}

final class SenderConfigurationStore {
    static let shared = SenderConfigurationStore()

    private enum Key {
        static let serviceName = "receiverServiceName"
        static let pairingCode = "pairingCode"
        static let quality = "streamQuality"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    func load() -> SenderConfiguration {
        SenderConfiguration(
            receiverServiceName: defaults.string(forKey: Key.serviceName) ?? "",
            pairingCode: defaults.string(forKey: Key.pairingCode) ?? "",
            quality: StreamQuality(rawValue: defaults.string(forKey: Key.quality) ?? "") ?? .balanced
        )
    }

    func save(_ configuration: SenderConfiguration) {
        defaults.set(configuration.receiverServiceName, forKey: Key.serviceName)
        defaults.set(PairingSecret.normalize(configuration.pairingCode), forKey: Key.pairingCode)
        defaults.set(configuration.quality.rawValue, forKey: Key.quality)
    }
}

