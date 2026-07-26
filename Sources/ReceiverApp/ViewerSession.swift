import Combine
import Foundation
import UIKit

final class ViewerSession: ObservableObject {
    @Published private(set) var identity: ReceiverIdentity
    @Published private(set) var serverState: ReceiverServer.State = .stopped
    @Published private(set) var hasPicture = false
    @Published private(set) var frameCount: UInt64 = 0

    let renderer = VideoRendererView()
    let pictureInPicture: PictureInPictureCoordinator

    private let server = ReceiverServer()
    private let decoder: H264DisplayDecoder
    private var cancellables: Set<AnyCancellable> = []

    init() {
        identity = ReceiverIdentityStore.shared.load()
        decoder = H264DisplayDecoder(renderer: renderer)
        pictureInPicture = PictureInPictureCoordinator(displayLayer: renderer.displayLayer)

        pictureInPicture.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        UIApplication.shared.isIdleTimerDisabled = true
        server.onStateChange = { [weak self] state in
            guard let self else { return }
            if case .connected = state {
                self.decoder.reset()
            }
            self.serverState = state
        }
        server.onPacket = { [weak self] packet in
            self?.handle(packet)
        }
        server.start(identity: identity)
    }

    var statusText: String {
        switch serverState {
        case .stopped:
            return "Starting…"
        case .advertising:
            return hasPicture ? "Reconnecting automatically…" : "Ready for sender"
        case .connected(let senderName):
            return "Connected to \(senderName)"
        case .waiting:
            return "Waiting for Local Network access"
        case .failed(let message):
            return "Network error: \(message)"
        }
    }

    func rotatePairingCode() {
        identity = ReceiverIdentityStore.shared.rotatePairingCode()
        hasPicture = false
        frameCount = 0
        decoder.reset()
        server.start(identity: identity)
    }

    private func handle(_ packet: WirePacket) {
        switch packet.kind {
        case .videoConfiguration:
            guard let configuration = try? JSONDecoder().decode(VideoConfiguration.self, from: packet.payload) else { return }
            decoder.configure(configuration)
            pictureInPicture.invalidatePlaybackState()
        case .videoFrame:
            decoder.enqueue(packet.payload)
            frameCount &+= 1
            hasPicture = true
        case .orientation:
            guard packet.payload.count == 4 else { return }
            let value = (UInt32(packet.payload[0]) << 24)
                | (UInt32(packet.payload[1]) << 16)
                | (UInt32(packet.payload[2]) << 8)
                | UInt32(packet.payload[3])
            decoder.updateOrientation(value)
        case .streamError:
            break
        default:
            break
        }
    }

    deinit {
        server.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
