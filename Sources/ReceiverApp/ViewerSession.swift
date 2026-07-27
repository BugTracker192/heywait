import Combine
import Foundation
import UIKit

final class ViewerSession: ObservableObject {
    @Published private(set) var identity: ReceiverIdentity
    @Published private(set) var serverState: ReceiverServer.State = .stopped
    @Published private(set) var hasPicture = false
    @Published private(set) var frameCount: UInt64 = 0
    @Published private(set) var videoStatus: String?

    let renderer = VideoRendererView()
    let pictureInPicture: PictureInPictureCoordinator

    private let server = ReceiverServer()
    private let decoder: H264DisplayDecoder
    private var cancellables: Set<AnyCancellable> = []
    private var pausedForBackground = false

    init() {
        identity = ReceiverIdentityStore.shared.load()
        decoder = H264DisplayDecoder(renderer: renderer)
        pictureInPicture = PictureInPictureCoordinator(displayLayer: renderer.displayLayer)

        renderer.onReadyForDisplay = { [weak self] in
            self?.videoStatus = nil
            self?.hasPicture = true
        }
        renderer.onDisplayLayerChanged = { [weak pictureInPicture = self.pictureInPicture] displayLayer in
            pictureInPicture?.updateDisplayLayer(displayLayer)
        }
        decoder.onKeyFrameEnqueued = { [weak self] in
            self?.videoStatus = nil
            self?.hasPicture = true
        }
        decoder.onFailure = { [weak self] message in
            self?.videoStatus = message
            self?.hasPicture = false
        }

        pictureInPicture.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        UIApplication.shared.isIdleTimerDisabled = true
        server.onStateChange = { [weak self] state in
            guard let self else { return }
            if case .connected = state {
                self.decoder.reset(preserveImage: self.hasPicture)
                self.videoStatus = nil
                if !self.hasPicture {
                    self.frameCount = 0
                }
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
        case .connected(let senderName) where hasPicture:
            return "Connected to \(senderName)"
        case .connected(let senderName):
            if let videoStatus {
                return videoStatus
            }
            return frameCount > 0
                ? "Connected to \(senderName) · decoding video…"
                : "Connected to \(senderName) · waiting for video…"
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
        videoStatus = nil
        decoder.reset()
        ReceiverOrientationCoordinator.shared.reset()
        server.start(identity: identity)
    }

    func enteredBackground() {
        guard !pictureInPicture.isActive, !pausedForBackground else { return }
        pausedForBackground = true
        server.stop()
    }

    func becameActive() {
        guard pausedForBackground else { return }
        pausedForBackground = false
        server.start(identity: identity)
    }

    private func handle(_ packet: WirePacket) {
        switch packet.kind {
        case .videoConfiguration:
            guard let configuration = try? JSONDecoder().decode(VideoConfiguration.self, from: packet.payload) else { return }
            ReceiverOrientationCoordinator.shared.update(configuration: configuration)
            decoder.configure(configuration)
            pictureInPicture.invalidatePlaybackState()
        case .videoFrame:
            frameCount &+= 1
            decoder.enqueue(
                packet.payload,
                isKeyFrame: packet.flags.contains(.keyFrame)
            )
        case .orientation:
            guard packet.payload.count == 4 else { return }
            let value = (UInt32(packet.payload[0]) << 24)
                | (UInt32(packet.payload[1]) << 16)
                | (UInt32(packet.payload[2]) << 8)
                | UInt32(packet.payload[3])
            ReceiverOrientationCoordinator.shared.update(videoOrientation: value)
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
