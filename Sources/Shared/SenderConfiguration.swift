import Foundation

enum StreamOrientationMode: String, CaseIterable {
    case automatic
    case landscape
    case portrait

    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        }
    }
}

enum StreamRotationDirection: String, CaseIterable {
    case left
    case right

    var title: String {
        switch self {
        case .left: return "Turn left"
        case .right: return "Turn right"
        }
    }
}

enum ViewerFramingMode: String, CaseIterable {
    case fit
    case fill
    case stretch

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        }
    }
}

struct SenderConfiguration: Equatable {
    var deliveryMode: DeliveryMode
    var receiverServiceName: String
    var pairingCode: String
    var quality: StreamQuality
    var browserAccessKey: String
    var orientationMode: StreamOrientationMode
    var rotationDirection: StreamRotationDirection
    var framingMode: ViewerFramingMode

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
        static let alwaysLandscape = "alwaysLandscape"
        static let orientationMode = "streamOrientationMode"
        static let rotationDirection = "streamRotationDirection"
        static let framingMode = "viewerFramingMode"
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
        let legacyAlwaysLandscape = defaults.object(forKey: Key.alwaysLandscape) == nil
            ? true
            : defaults.bool(forKey: Key.alwaysLandscape)
        let orientationMode = StreamOrientationMode(
            rawValue: defaults.string(forKey: Key.orientationMode) ?? ""
        ) ?? (legacyAlwaysLandscape ? .landscape : .automatic)
        let rotationDirection = StreamRotationDirection(
            rawValue: defaults.string(forKey: Key.rotationDirection) ?? ""
        ) ?? .left
        let framingMode = ViewerFramingMode(
            rawValue: defaults.string(forKey: Key.framingMode) ?? ""
        ) ?? .fill

        return SenderConfiguration(
            deliveryMode: DeliveryMode(rawValue: defaults.string(forKey: Key.deliveryMode) ?? "") ?? .nativeReceiver,
            receiverServiceName: defaults.string(forKey: Key.serviceName) ?? "",
            pairingCode: defaults.string(forKey: Key.pairingCode) ?? "",
            quality: StreamQuality(rawValue: defaults.string(forKey: Key.quality) ?? "") ?? .balanced,
            browserAccessKey: PairingSecret.normalize(savedBrowserKey),
            orientationMode: orientationMode,
            rotationDirection: rotationDirection,
            framingMode: framingMode
        )
    }

    func save(_ configuration: SenderConfiguration) {
        defaults.set(configuration.deliveryMode.rawValue, forKey: Key.deliveryMode)
        defaults.set(configuration.receiverServiceName, forKey: Key.serviceName)
        defaults.set(PairingSecret.normalize(configuration.pairingCode), forKey: Key.pairingCode)
        defaults.set(configuration.quality.rawValue, forKey: Key.quality)
        defaults.set(PairingSecret.normalize(configuration.browserAccessKey), forKey: Key.browserAccessKey)
        defaults.set(configuration.orientationMode.rawValue, forKey: Key.orientationMode)
        defaults.set(configuration.rotationDirection.rawValue, forKey: Key.rotationDirection)
        defaults.set(configuration.framingMode.rawValue, forKey: Key.framingMode)
        // Preserve compatibility if an older containing app is briefly opened.
        defaults.set(configuration.orientationMode == .landscape, forKey: Key.alwaysLandscape)
        defaults.synchronize()
    }
}

