import Foundation
import Network

final class SenderTransport {
    private struct PendingPacket {
        let kind: PacketKind
        let flags: PacketFlags
        let payload: Data

        var isVideoFrame: Bool { kind == .videoFrame }
        var isAudioFrame: Bool { kind == .audioPCM }
    }

    private let configuration: SenderConfiguration
    private let queue = DispatchQueue(label: "dev.screenshare.sender.transport")
    private let codec: SecurePacketCodec
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var parser = PacketStreamParser()
    private var heartbeat: DispatchSourceTimer?
    private var pending: [PendingPacket] = []
    private var inFlightSends = 0
    private var sequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var authenticated = false
    private let stateLock = NSLock()
    private var _isReady = false
    private var _outstandingVideoFrames = 0

    var onReady: (() -> Void)?
    var onDisconnected: (() -> Void)?

    init(configuration: SenderConfiguration) {
        self.configuration = configuration
        codec = SecurePacketCodec(pairingCode: configuration.pairingCode)
    }

    var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isReady
    }

    var canEncodeNextFrame: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isReady
            && _outstandingVideoFrames < AppConstants.maximumOutstandingVideoFrames
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.beginBrowsing(generation: self.generation)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.browser?.cancel()
            self.browser = nil
            self.connection?.cancel()
            self.connection = nil
            self.heartbeat?.cancel()
            self.heartbeat = nil
            self.pending.removeAll()
            self.inFlightSends = 0
            self.setReady(false)
            self.resetOutstandingVideoFrames()
        }
    }

    func sendVideoConfiguration(_ configuration: VideoConfiguration) {
        guard let payload = try? JSONEncoder().encode(configuration) else { return }
        enqueue(kind: .videoConfiguration, payload: payload)
    }

    func sendVideoFrame(_ data: Data, isKeyFrame: Bool) {
        // Once VideoToolbox emits a frame, later frames may reference it. Track
        // backpressure here, but never discard an encoded access unit.
        adjustOutstandingVideoFrames(by: 1)
        enqueue(
            kind: .videoFrame,
            flags: isKeyFrame ? .keyFrame : [],
            payload: data,
            tracksOutstandingVideoFrame: true
        )
    }

    func sendAudio(_ frame: AudioPCMFrame) {
        enqueue(kind: .audioPCM, payload: frame.encoded)
    }

    func sendOrientation(_ orientation: UInt32) {
        var value = orientation.bigEndian
        let payload = withUnsafeBytes(of: &value) { Data($0) }
        enqueue(kind: .orientation, payload: payload)
    }

    private func enqueue(
        kind: PacketKind,
        flags: PacketFlags = [],
        payload: Data,
        tracksOutstandingVideoFrame: Bool = false
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.authenticated else {
                if tracksOutstandingVideoFrame {
                    self.adjustOutstandingVideoFrames(by: -1)
                }
                return
            }

            if kind == .audioPCM {
                let audioCount = self.pending.reduce(into: 0) { count, packet in
                    if packet.isAudioFrame { count += 1 }
                }
                if audioCount >= AppConstants.maximumPendingAudioFrames,
                   let staleIndex = self.pending.firstIndex(where: \.isAudioFrame) {
                    self.pending.remove(at: staleIndex)
                }
            }
            self.pending.append(PendingPacket(kind: kind, flags: flags, payload: payload))
            self.pump()
        }
    }

    private func beginBrowsing(generation: UInt64) {
        guard generation == self.generation else { return }
        browser?.cancel()
        connection?.cancel()
        browser = nil
        connection = nil
        parser = PacketStreamParser()
        pending.removeAll()
        inFlightSends = 0
        resetOutstandingVideoFrames()
        authenticated = false
        setReady(false)

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: AppConstants.serviceType, domain: AppConstants.serviceDomain),
            using: parameters
        )
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            guard let endpoint = results.first(where: { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return false }
                return name == self.configuration.receiverServiceName
            })?.endpoint else { return }
            self.connect(to: endpoint, generation: generation)
        }

        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.scheduleReconnect(generation: generation)
            }
        }
        browser.start(queue: queue)
    }

    private func connect(to endpoint: NWEndpoint, generation: UInt64) {
        guard generation == self.generation, connection == nil else { return }
        browser?.cancel()
        browser = nil

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 3
        tcp.keepaliveInterval = 2
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo

        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            switch state {
            case .ready:
                self.receiveNext(on: connection, generation: generation)
                self.startHeartbeat()
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, generation == self.generation, !self.authenticated else { return }
                    self.restart(generation: generation)
                }
            case .failed, .cancelled:
                self.restart(generation: generation)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendHello(receiverChallenge: Data) {
        guard receiverChallenge.count == 32 else { return }
        let hello = HelloPayload(
            protocolVersion: Int(AppConstants.protocolVersion),
            sessionID: UUID(),
            senderName: ProcessInfo.processInfo.hostName,
            sentAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000),
            receiverChallenge: receiverChallenge
        )
        guard let payload = try? JSONEncoder().encode(hello) else { return }
        sendImmediately(kind: .hello, payload: payload)
    }

    private func sendImmediately(kind: PacketKind, payload: Data = Data()) {
        guard let connection else { return }
        sequence &+= 1
        guard let encoded = try? codec.encode(kind: kind, sequence: sequence, payload: payload) else { return }
        connection.send(content: encoded, completion: .contentProcessed { _ in })
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.authenticated else { return }
            self.pending.append(PendingPacket(kind: .heartbeat, flags: [], payload: Data()))
            self.pump()
        }
        heartbeat = timer
        timer.resume()
    }

    private func receiveNext(on connection: NWConnection, generation: UInt64) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, connection === self.connection, generation == self.generation else { return }
            do {
                if let data, !data.isEmpty {
                    let packets = try self.parser.append(data, using: self.codec)
                    for packet in packets {
                        switch packet.kind {
                        case .challenge where !self.authenticated:
                            self.sendHello(receiverChallenge: packet.payload)
                        case .helloAcknowledgement:
                            guard let acknowledgement = try? JSONDecoder().decode(HelloAcknowledgement.self, from: packet.payload),
                                  acknowledgement.protocolVersion == Int(AppConstants.protocolVersion) else { continue }
                            if !self.authenticated {
                                self.authenticated = true
                                self.setReady(true)
                                DispatchQueue.main.async { self.onReady?() }
                            }
                        default:
                            break
                        }
                    }
                }
            } catch {
                connection.cancel()
                return
            }

            if isComplete || error != nil {
                self.restart(generation: generation)
            } else {
                self.receiveNext(on: connection, generation: generation)
            }
        }
    }

    private func pump() {
        guard authenticated, let connection, !pending.isEmpty else { return }

        connection.batch {
            while inFlightSends < AppConstants.maximumInFlightNetworkSends,
                  !pending.isEmpty {
                let next = pending.removeFirst()
                sequence &+= 1

                guard let data = try? codec.encode(
                    kind: next.kind,
                    flags: next.flags,
                    sequence: sequence,
                    payload: next.payload
                ) else {
                    if next.isVideoFrame {
                        adjustOutstandingVideoFrames(by: -1)
                    }
                    continue
                }

                inFlightSends += 1
                connection.send(
                    content: data,
                    completion: .contentProcessed { [weak self, weak connection] error in
                        guard let self,
                              let connection,
                              connection === self.connection else { return }
                        if next.isVideoFrame {
                            self.adjustOutstandingVideoFrames(by: -1)
                        }
                        self.inFlightSends = max(0, self.inFlightSends - 1)
                        if error == nil {
                            self.pump()
                        } else {
                            self.restart(generation: self.generation)
                        }
                    }
                )
            }
        }
    }

    private func restart(generation: UInt64) {
        guard generation == self.generation else { return }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        heartbeat?.cancel()
        heartbeat = nil
        authenticated = false
        pending.removeAll()
        inFlightSends = 0
        resetOutstandingVideoFrames()
        let wasReady = isReady
        setReady(false)
        if wasReady {
            DispatchQueue.main.async { [weak self] in self?.onDisconnected?() }
        }
        scheduleReconnect(generation: generation)
    }

    private func scheduleReconnect(generation: UInt64) {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, generation == self.generation else { return }
            self.beginBrowsing(generation: generation)
        }
    }

    private func setReady(_ value: Bool) {
        stateLock.lock()
        _isReady = value
        stateLock.unlock()
    }

    private func adjustOutstandingVideoFrames(by delta: Int) {
        stateLock.lock()
        _outstandingVideoFrames = max(0, _outstandingVideoFrames + delta)
        stateLock.unlock()
    }

    private func resetOutstandingVideoFrames() {
        stateLock.lock()
        _outstandingVideoFrames = 0
        stateLock.unlock()
    }
}
