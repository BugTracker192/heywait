import CoreMedia
import Foundation
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private var transport: SenderTransport?
    private var encoder: H264Encoder?
    private var browserServer: BrowserStreamServer?
    private var browserEncoder: BrowserJPEGEncoder?
    private var browserH264Encoder: H264Encoder?
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
                    userInfo: [NSLocalizedDescriptionKey: "Open Screen Share Sender and save a viewing method first."]
                )
            )
            return
        }

        switch configuration.deliveryMode {
        case .nativeReceiver:
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

        case .browser:
            let server = BrowserStreamServer(accessKey: configuration.browserAccessKey)
            let jpegEncoder = BrowserJPEGEncoder(quality: configuration.quality)
            let h264Encoder = H264Encoder(quality: configuration.quality)
            self.browserServer = server
            self.browserEncoder = jpegEncoder
            self.browserH264Encoder = h264Encoder

            jpegEncoder.onFrame = { [weak server] jpeg in
                server?.publish(jpeg: jpeg)
            }
            h264Encoder.onFrame = { [weak server] frame in
                server?.publish(h264: frame)
            }
            h264Encoder.onFailure = { [weak self] message in
                self?.stopWithError(message)
            }
            server.onH264ClientReady = { [weak h264Encoder] in
                h264Encoder?.requestKeyFrame()
            }
            server.onFailure = { [weak self] message in
                self?.stopWithError(message)
            }
            server.start()
        }
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
        browserH264Encoder?.invalidate()
        browserServer?.stop()
        transport = nil
        encoder = nil
        browserServer = nil
        browserEncoder = nil
        browserH264Encoder = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard !isPaused,
              !isFinishing,
              sampleBufferType == .video else {
            return
        }

        autoreleasepool {
            let orientation = videoOrientation(from: sampleBuffer)
            if let browserServer, browserServer.hasH264Clients, let browserH264Encoder {
                if orientation != lastOrientation {
                    lastOrientation = orientation
                    browserH264Encoder.requestKeyFrame()
                }
                browserH264Encoder.encode(sampleBuffer, orientation: orientation)
            } else if let browserServer, browserServer.hasMJPEGClients, let browserEncoder {
                guard browserServer.hasStreamingClients else { return }
                lastOrientation = orientation
                browserEncoder.encode(sampleBuffer, orientation: orientation)
            } else if transport?.canEncodeNextFrame == true {
                if orientation != lastOrientation {
                    lastOrientation = orientation
                    transport?.sendOrientation(orientation)
                    encoder?.requestKeyFrame()
                }
                encoder?.encode(sampleBuffer, orientation: orientation)
            }
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
