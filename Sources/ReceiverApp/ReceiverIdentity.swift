import Foundation
import UIKit

struct ReceiverIdentity: Equatable {
    let identifier: String
    let displayName: String
    let pairingCode: String

    var serviceName: String {
        "ScreenShare-\(identifier.prefix(8).uppercased())"
    }
}

final class ReceiverIdentityStore {
    static let shared = ReceiverIdentityStore()

    private enum Key {
        static let identifier = "receiverIdentifier"
        static let pairingCode = "receiverPairingCode"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ReceiverIdentity {
        let identifier: String
        if let saved = defaults.string(forKey: Key.identifier), !saved.isEmpty {
            identifier = saved
        } else {
            identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            defaults.set(identifier, forKey: Key.identifier)
        }

        let pairingCode: String
        if let saved = defaults.string(forKey: Key.pairingCode), PairingSecret.isValid(saved) {
            pairingCode = PairingSecret.format(saved)
        } else {
            pairingCode = PairingSecret.generate()
            defaults.set(PairingSecret.normalize(pairingCode), forKey: Key.pairingCode)
        }

        return ReceiverIdentity(
            identifier: identifier,
            displayName: UIDevice.current.name,
            pairingCode: pairingCode
        )
    }

    @discardableResult
    func rotatePairingCode() -> ReceiverIdentity {
        defaults.set(PairingSecret.normalize(PairingSecret.generate()), forKey: Key.pairingCode)
        return load()
    }
}

