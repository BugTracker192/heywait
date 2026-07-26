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
    private var retryWorkItem: DispatchWorkItem?
    private var retryAttempt = 0
    private var shouldBrowse = false

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldBrowse = true
            self.startBrowserIfNeeded()
        }
    }

    func retryNow() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldBrowse = true
            self.retryAttempt = 0
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.browser?.stateUpdateHandler = nil
            self.browser?.browseResultsChangedHandler = nil
            self.browser?.cancel()
            self.browser = nil
            self.publish(receivers: [], status: "Refreshing receiver discovery…")
            self.startBrowserIfNeeded()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldBrowse = false
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.browser?.stateUpdateHandler = nil
            self.browser?.browseResultsChangedHandler = nil
            self.browser?.cancel()
            self.browser = nil
        }
    }

    private func startBrowserIfNeeded() {
        guard shouldBrowse, browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: AppConstants.serviceType, domain: AppConstants.serviceDomain),
            using: parameters
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            switch state {
            case .ready:
                self.retryAttempt = 0
                self.publish(status: "Select the receiving iPhone")
            case .waiting(let error):
                self.publish(status: Self.message(for: error))
            case .failed(let error):
                self.browser = nil
                browser.stateUpdateHandler = nil
                browser.browseResultsChangedHandler = nil
                browser.cancel()
                self.publish(
                    receivers: [],
                    status: Self.isLocalNetworkDenied(error)
                        ? "Allow Local Network access, then tap Retry"
                        : "Receiver discovery was interrupted — retrying…"
                )
                self.scheduleRetry()
            case .cancelled:
                self.browser = nil
            default:
                self.publish(status: "Looking for receivers…")
            }
        }

        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            let discovered = results.compactMap { result -> DiscoveredReceiver? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredReceiver(name: name, endpoint: result.endpoint)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.publish(
                receivers: discovered,
                status: discovered.isEmpty
                    ? "Open Screen Share on the receiving iPhone"
                    : "Select the receiving iPhone"
            )
        }
        browser.start(queue: queue)
    }

    private func scheduleRetry() {
        guard shouldBrowse, retryWorkItem == nil else { return }
        retryAttempt += 1
        let delay = min(pow(2.0, Double(retryAttempt - 1)) * 0.5, 4)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            self.startBrowserIfNeeded()
        }
        retryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private static func message(for error: NWError) -> String {
        if isLocalNetworkDenied(error) {
            return "Allow Local Network access in Settings"
        }
        return "Waiting for the local network…"
    }

    private static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65570 {
            return true
        }
        if case .posix(let code) = error, code.rawValue == 1 {
            return true
        }
        return false
    }

    private func publish(receivers: [DiscoveredReceiver]? = nil, status: String) {
        DispatchQueue.main.async { [weak self] in
            if let receivers {
                self?.receivers = receivers
            }
            self?.status = status
        }
    }

    deinit {
        retryWorkItem?.cancel()
        browser?.cancel()
    }
}
