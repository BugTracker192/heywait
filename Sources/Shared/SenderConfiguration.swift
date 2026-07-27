import Foundation

struct SenderConfiguration: Equatable {
    var deliveryMode: DeliveryMode
    var receiverServiceName: String
    var pairingCode: String
    var quality: StreamQuality
    var browserAccessKey: String

    var isReady: Bool {
        switch deliveryMode {
        case .nativeReceiver:
            return !receiverServiceName.isEmpty && PairingSecret.isValid(pairingCode)
        case .browser:
            return PairingSecret.isValid(browserAccessKey)
        }
    }
}

final class SenderConfigurationStore {
    static let shared = SenderConfigurationStore()

    private enum Key {
        static let deliveryMode = "deliveryMode"
        static let serviceName = "receiverServiceName"
        static let pairingCode = "pairingCode"
        static let quality = "streamQuality"
        static let browserAccessKey = "browserAccessKey"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    func load() -> SenderConfiguration {
        // The containing app and ReplayKit extension are separate processes.
        // Refresh the App Group domain before selecting a transport.
        defaults.synchronize()
        let savedBrowserKey = defaults.string(forKey: Key.browserAccessKey) ?? PairingSecret.generate()
        if defaults.string(forKey: Key.browserAccessKey) == nil {
            defaults.set(PairingSecret.normalize(savedBrowserKey), forKey: Key.browserAccessKey)
            defaults.synchronize()
        }
        return SenderConfiguration(
            deliveryMode: DeliveryMode(rawValue: defaults.string(forKey: Key.deliveryMode) ?? "") ?? .nativeReceiver,
            receiverServiceName: defaults.string(forKey: Key.serviceName) ?? "",
            pairingCode: defaults.string(forKey: Key.pairingCode) ?? "",
            quality: StreamQuality(rawValue: defaults.string(forKey: Key.quality) ?? "") ?? .balanced,
            browserAccessKey: PairingSecret.normalize(savedBrowserKey)
        )
    }

    func save(_ configuration: SenderConfiguration) {
        defaults.set(configuration.deliveryMode.rawValue, forKey: Key.deliveryMode)
        defaults.set(configuration.receiverServiceName, forKey: Key.serviceName)
        defaults.set(PairingSecret.normalize(configuration.pairingCode), forKey: Key.pairingCode)
        defaults.set(configuration.quality.rawValue, forKey: Key.quality)
        defaults.set(PairingSecret.normalize(configuration.browserAccessKey), forKey: Key.browserAccessKey)
        defaults.synchronize()
    }
}

