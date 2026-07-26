import Combine
import Foundation
import Network

struct DiscoveredReceiver: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint

    var id: String { name }
}

final class ReceiverDiscovery: ObservableObject {
    @Published private(set) var receivers: [DiscoveredReceiver] = []
    @Published private(set) var status = "Looking for receivers…"

    private let queue = DispatchQueue(label: "dev.screenshare.discovery")
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: AppConstants.serviceType, domain: AppConstants.serviceDomain),
            using: parameters
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            let message: String
            switch state {
            case .ready:
                message = "Select the receiving iPhone"
            case .waiting(let error):
                message = Self.message(for: error)
            case .failed(let error):
                message = "Discovery failed: \(error.localizedDescription)"
            case .cancelled:
                message = "Discovery stopped"
            default:
                message = "Looking for receivers…"
            }
            DispatchQueue.main.async { self?.status = message }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let receivers = results.compactMap { result -> DiscoveredReceiver? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredReceiver(name: name, endpoint: result.endpoint)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self?.receivers = receivers
                if receivers.isEmpty {
                    self?.status = "Open Screen Share on the receiving iPhone"
                }
            }
        }
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private static func message(for error: NWError) -> String {
        if case .dns(let code) = error, code == -65570 {
            return "Allow Local Network access in Settings"
        }
        return "Waiting for the local network"
    }

    deinit {
        browser?.cancel()
    }
}

