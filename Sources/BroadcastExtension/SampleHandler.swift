import CoreMedia
import Foundation
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private var transport: SenderTransport?
    private var encoder: H264Encoder?
    private var isPaused = false
    private var lastOrientation: UInt32 = 1
    private var isFinishing = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let configuration = SenderConfigurationStore.shared.load()
        guard configuration.isReady else {
            finishBroadcastWithError(
                NSError(
                    domain: "dev.screenshare.broadcast",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Open Screen Share Sender and pair a receiver first."]
                )
            )
            return
        }

        let encoder = H264Encoder(quality: configuration.quality)
        let transport = SenderTransport(configuration: configuration)
        self.encoder = encoder
        self.transport = transport

        encoder.onFrame = { [weak transport] frame in
            if let configuration = frame.configuration {
                transport?.sendVideoConfiguration(configuration)
            }
            transport?.sendVideoFrame(frame.data, isKeyFrame: frame.isKeyFrame)
        }
        encoder.onFailure = { [weak self] message in
            self?.stopWithError(message)
        }
        transport.onReady = { [weak encoder] in
            encoder?.requestKeyFrame()
        }
        transport.start()
    }

    override func broadcastPaused() {
        isPaused = true
    }

    override func broadcastResumed() {
        isPaused = false
        encoder?.requestKeyFrame()
    }

    override func broadcastFinished() {
        isFinishing = true
        transport?.stop()
        encoder?.invalidate()
        transport = nil
        encoder = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard !isPaused,
              !isFinishing,
              sampleBufferType == .video,
              transport?.canEncodeNextFrame == true else {
            return
        }

        autoreleasepool {
            let orientation = videoOrientation(from: sampleBuffer)
            if orientation != lastOrientation {
                lastOrientation = orientation
                transport?.sendOrientation(orientation)
                encoder?.requestKeyFrame()
            }
            encoder?.encode(sampleBuffer, orientation: orientation)
        }
    }

    private func stopWithError(_ message: String) {
        guard !isFinishing else { return }
        isFinishing = true
        finishBroadcastWithError(
            NSError(
                domain: "dev.screenshare.broadcast",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
    }

    private func videoOrientation(from sampleBuffer: CMSampleBuffer) -> UInt32 {
        let value = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        )
        return (value as? NSNumber)?.uint32Value ?? lastOrientation
    }
}
