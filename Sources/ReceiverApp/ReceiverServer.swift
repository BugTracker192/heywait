import Foundation
import Network

final class ReceiverServer {
    enum State: Equatable {
        case stopped
        case advertising
        case connected(senderName: String)
        case waiting(String)
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    var onPacket: ((WirePacket) -> Void)?

    private let queue = DispatchQueue(label: "dev.screenshare.receiver.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ReceiverClient] = [:]
    private var activeClientID: ObjectIdentifier?
    private var identity: ReceiverIdentity?
    private let deliveryLock = NSLock()
    private var pendingVideoPacket: WirePacket?
    private var videoDeliveryScheduled = false
    private var deliveryGeneration: UInt64 = 0

    func start(identity: ReceiverIdentity) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal()
            self.identity = identity

            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 3
            tcp.keepaliveInterval = 2
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.includePeerToPeer = true

            do {
                let listener = try NWListener(using: parameters)
                let txt = NetService.data(fromTXTRecord: [
                    "id": Data(identity.identifier.utf8),
                    "version": Data(String(AppConstants.protocolVersion).utf8)
                ])
                listener.service = NWListener.Service(
                    name: identity.serviceName,
                    type: AppConstants.serviceType,
                    domain: nil,
                    txtRecord: txt
                )
                self.listener = listener

                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, listener === self.listener else { return }
                    switch state {
                    case .ready:
                        self.publish(.advertising)
                    case .waiting(let error):
                        self.publish(.waiting(error.localizedDescription))
                    case .failed(let error):
                        self.publish(.failed(error.localizedDescription))
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.queue)
            } catch {
                self.publish(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
            self?.publish(.stopped)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let identity else {
            connection.cancel()
            return
        }
        guard clients.count < 8 else {
            connection.cancel()
            return
        }

        let client = ReceiverClient(connection: connection, pairingCode: identity.pairingCode, queue: queue)
        let identifier = ObjectIdentifier(client)
        clients[identifier] = client

        client.onHello = { [weak self, weak client] hello in
            guard let self, let client else { return }
            let clientID = ObjectIdentifier(client)
            if let oldID = self.activeClientID, oldID != clientID {
                self.clients[oldID]?.stop()
                self.clients.removeValue(forKey: oldID)
            }
            self.activeClientID = clientID
            self.publish(.connected(senderName: hello.senderName))
        }

        client.onPacket = { [weak self, weak client] packet in
            guard let self, let client, ObjectIdentifier(client) == self.activeClientID else { return }
            self.deliver(packet)
        }

        client.onStop = { [weak self, weak client] in
            guard let self, let client else { return }
            let clientID = ObjectIdentifier(client)
            self.clients.removeValue(forKey: clientID)
            if self.activeClientID == clientID {
                self.activeClientID = nil
                self.publish(.advertising)
            }
        }
        client.start(receiverName: identity.displayName)
    }

    private func stopInternal() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        for client in Array(clients.values) {
            client.stop()
        }
        clients.removeAll()
        activeClientID = nil
        deliveryLock.lock()
        deliveryGeneration &+= 1
        pendingVideoPacket = nil
        videoDeliveryScheduled = false
        deliveryLock.unlock()
    }

    private func publish(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }

    private func deliver(_ packet: WirePacket) {
        guard packet.kind == .videoFrame else {
            DispatchQueue.main.async { [weak self] in self?.onPacket?(packet) }
            return
        }

        deliveryLock.lock()
        if pendingVideoPacket?.flags.contains(.keyFrame) != true || packet.flags.contains(.keyFrame) {
            pendingVideoPacket = packet
        }
        let shouldSchedule = !videoDeliveryScheduled
        videoDeliveryScheduled = true
        let generation = deliveryGeneration
        deliveryLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliveryLock.lock()
            guard generation == self.deliveryGeneration else {
                self.deliveryLock.unlock()
                return
            }
            let latest = self.pendingVideoPacket
            self.pendingVideoPacket = nil
            self.videoDeliveryScheduled = false
            self.deliveryLock.unlock()
            if let latest {
                self.onPacket?(latest)
            }
        }
    }
}

private final class ReceiverClient {
    var onHello: ((HelloPayload) -> Void)?
    var onPacket: ((WirePacket) -> Void)?
    var onStop: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let codec: SecurePacketCodec
    private var parser = PacketStreamParser()
    private var authenticated = false
    private var stopped = false
    private var outgoingSequence: UInt64 = 0
    private var lastIncomingSequence: UInt64 = 0
    private var receiverName = "iPhone"
    private let challenge = PairingSecret.randomData(count: 32)

    init(connection: NWConnection, pairingCode: String, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        codec = SecurePacketCodec(pairingCode: pairingCode)
    }

    func start(receiverName: String) {
        self.receiverName = receiverName
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self else { return }
                self.send(kind: .challenge, payload: self.challenge)
                self.receiveNext()
            case .failed, .cancelled:
                self?.stop()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.authenticated else { return }
            self.stop()
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onStop?()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            do {
                if let data, !data.isEmpty {
                    for packet in try self.parser.append(data, using: self.codec) {
                        guard packet.sequence > self.lastIncomingSequence else { continue }
                        self.lastIncomingSequence = packet.sequence
                        try self.handle(packet)
                    }
                }
            } catch {
                self.stop()
                return
            }

            if isComplete || error != nil {
                self.stop()
            } else {
                self.receiveNext()
            }
        }
    }

    private func handle(_ packet: WirePacket) throws {
        if !authenticated {
            guard packet.kind == .hello else {
                throw WireProtocolError.authenticationFailed
            }
            let hello = try JSONDecoder().decode(HelloPayload.self, from: packet.payload)
            guard hello.protocolVersion == Int(AppConstants.protocolVersion) else {
                throw WireProtocolError.unsupportedVersion(UInt8(clamping: hello.protocolVersion))
            }
            guard hello.receiverChallenge == challenge else {
                throw WireProtocolError.authenticationFailed
            }
            authenticated = true
            sendAcknowledgement()
            onHello?(hello)
            return
        }

        if packet.kind != .heartbeat {
            onPacket?(packet)
        }
    }

    private func sendAcknowledgement() {
        let acknowledgement = HelloAcknowledgement(
            protocolVersion: Int(AppConstants.protocolVersion),
            receiverName: receiverName
        )
        guard let payload = try? JSONEncoder().encode(acknowledgement) else { return }
        send(kind: .helloAcknowledgement, payload: payload)
    }

    private func send(kind: PacketKind, payload: Data) {
        outgoingSequence &+= 1
        guard let data = try? codec.encode(kind: kind, sequence: outgoingSequence, payload: payload) else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.stop() }
        })
    }
}
