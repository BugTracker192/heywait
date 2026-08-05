import CoreMedia
import CoreVideo
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
    private var lastOrientationDiagnostic = ""
    private var lastAudioDiagnostic = ""
    private var lastVideoDiagnostic = ""
    private var quality: StreamQuality = .balanced
    private var orientationMode: StreamOrientationMode = .landscape
    private var rotationDirection: StreamRotationDirection = .left
    private var isFinishing = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let configuration = SenderConfigurationStore.shared.load()
        quality = configuration.quality
        orientationMode = configuration.orientationMode
        rotationDirection = configuration.rotationDirection
        guard configuration.deliveryMode == .browser || configuration.isReady else {
            finishBroadcastWithError(
                NSError(
                    domain: "dev.screenshare.broadcast",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Open Screen Share Sender and save a viewing method first."]
                )
            )
            return
        }

        // Always expose the private browser viewer while a broadcast is live.
        // This makes the QR resilient to a stale mode selection and also lets
        // the native receiver and browser viewer be used during the same
        // session. Video is only encoded for a browser after it connects.
        let server = BrowserStreamServer(accessKey: configuration.browserAccessKey)
        let jpegEncoder = BrowserJPEGEncoder(quality: configuration.quality)
        let h264Encoder = H264Encoder(quality: configuration.quality)
        browserServer = server
        browserEncoder = jpegEncoder
        browserH264Encoder = h264Encoder

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
            guard configuration.deliveryMode == .browser else { return }
            self?.stopWithError(message)
        }
        server.start()

        if configuration.deliveryMode == .nativeReceiver {
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
    }

    override func broadcastPaused() {
        isPaused = true
    }

    override func broadcastResumed() {
        isPaused = false
        encoder?.requestKeyFrame()
        browserH264Encoder?.requestKeyFrame()
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
              !isFinishing else {
            return
        }

        autoreleasepool {
            if sampleBufferType == .audioApp || sampleBufferType == .audioMic {
                // Microphone frames were previously discarded, so the streamer
                // could never be heard. Tag the source and forward both: the
                // receiver mixes them, which avoids resampling two independent
                // ReplayKit clocks inside the extension's memory budget.
                let isMicrophone = sampleBufferType == .audioMic
                let frame = CapturedAudioPCMFrame.make(
                    from: sampleBuffer,
                    isMicrophone: isMicrophone
                )
                recordAudioDiagnostic(
                    for: sampleBuffer,
                    source: isMicrophone ? "mic" : "app",
                    accepted: frame != nil
                )
                guard let frame else { return }
                browserServer?.publish(audio: frame)
                if transport?.isReady == true {
                    transport?.sendAudio(frame)
                }
                return
            }
            guard sampleBufferType == .video else { return }

            recordVideoDiagnostic(for: sampleBuffer)

            let orientation = videoOrientation(from: sampleBuffer)
            let orientationChanged = orientation != lastOrientation
            if orientationChanged {
                lastOrientation = orientation
                transport?.sendOrientation(orientation)
                encoder?.requestKeyFrame()
                browserH264Encoder?.requestKeyFrame()
            }

            if let browserServer {
                if browserServer.hasH264Clients {
                    if browserServer.canEncodeNextH264Frame,
                       let browserH264Encoder {
                        browserH264Encoder.encode(sampleBuffer, orientation: orientation)
                    }
                }
                if browserServer.hasMJPEGClients, let browserEncoder {
                    browserEncoder.encode(sampleBuffer, orientation: orientation)
                }
            }

            if transport?.canEncodeNextFrame == true {
                encoder?.encode(sampleBuffer, orientation: orientation)
            }
        }
    }

    private func recordVideoDiagnostic(for sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sourceWidth = Int32(CVPixelBufferGetWidth(imageBuffer))
        let sourceHeight = Int32(CVPixelBufferGetHeight(imageBuffer))
        guard sourceWidth > 0, sourceHeight > 0 else { return }

        let target = quality.encodedDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        let megabits = Double(
            quality.bitRate(width: target.width, height: target.height)
        ) / 1_000_000

        // Which transport the viewer actually negotiated. The MJPEG fallback is
        // bounded by browserMaximumDimension rather than the H.264 short-edge
        // bound, so a silent fall back looks exactly like no improvement at all.
        let viewer: String
        if let browserServer {
            if browserServer.hasH264Clients {
                viewer = "h264"
            } else if browserServer.hasMJPEGClients {
                viewer = "mjpeg"
            } else {
                viewer = "none"
            }
        } else {
            viewer = "off"
        }

        let diagnostic = "encode \(sourceWidth)x\(sourceHeight)"
            + " -> \(target.width)x\(target.height)"
            + " @ \(String(format: "%.1f", megabits))Mbps"
            + " \(quality.rawValue) · viewer \(viewer)"
        guard diagnostic != lastVideoDiagnostic else { return }
        lastVideoDiagnostic = diagnostic
        UserDefaults(suiteName: AppConstants.appGroup)?.set(
            diagnostic,
            forKey: AppConstants.videoDiagnosticKey
        )
    }

    private func recordAudioDiagnostic(
        for sampleBuffer: CMSampleBuffer,
        source: String,
        accepted: Bool
    ) {
        let diagnostic = "\(source) audio "
            + CapturedAudioPCMFrame.formatSummary(of: sampleBuffer)
            + " -> \(accepted ? "ok" : "REJECTED")"
        // Audio arrives around a hundred times a second, so only persist when the
        // description actually changes. That still captures the moment another
        // app reshapes the session and the format starts being rejected.
        guard diagnostic != lastAudioDiagnostic else { return }
        lastAudioDiagnostic = diagnostic
        UserDefaults(suiteName: AppConstants.appGroup)?.set(
            diagnostic,
            forKey: AppConstants.audioDiagnosticKey
        )
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
        let dimensions: (width: Int, height: Int)
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            dimensions = (
                CVPixelBufferGetWidth(imageBuffer),
                CVPixelBufferGetHeight(imageBuffer)
            )
        } else {
            dimensions = (0, 0)
        }
        let rawOrientation = (value as? NSNumber)?.uint32Value
        let replayKitOrientation = ReplayKitOrientationResolver.resolve(
            attachedValue: rawOrientation,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height
        )
        let resolvedOrientation = StreamOrientationPolicy.resolve(
            orientation: replayKitOrientation,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            mode: orientationMode,
            direction: rotationDirection
        )
        let rawDescription = rawOrientation.map { String($0) } ?? "none"
        let diagnostic = "ReplayKit \(dimensions.width)x\(dimensions.height) raw \(rawDescription) -> sent \(resolvedOrientation) [\(orientationMode.rawValue), \(rotationDirection.rawValue)]"
        if diagnostic != lastOrientationDiagnostic {
            lastOrientationDiagnostic = diagnostic
            UserDefaults(suiteName: AppConstants.appGroup)?.set(
                diagnostic,
                forKey: AppConstants.orientationDiagnosticKey
            )
        }
        return resolvedOrientation
    }
}
