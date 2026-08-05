import AVFoundation
import Foundation
import VideoToolbox

final class H264Encoder {
    struct EncodedFrame {
        let data: Data
        let isKeyFrame: Bool
        let configuration: VideoConfiguration?
        let timestampMicroseconds: Int64
    }

    var onFrame: ((EncodedFrame) -> Void)?
    var onFailure: ((String) -> Void)?

    private let quality: StreamQuality

    // Three threads touch this object:
    //   * ReplayKit's sample thread calls encode().
    //   * VideoToolbox's own thread calls the output callback, so handle() and
    //     makeConfiguration() run there.
    //   * requestKeyFrame() is called from BrowserStreamServer's HTTP queue
    //     (onH264ClientReady), from the main thread (broadcastResumed) and from
    //     the sample thread (orientation change).
    // `stateLock` guards exactly the fields those threads share. Reading
    // `dimensions` and `currentOrientation` together under it is what stops a
    // key frame from shipping a VideoConfiguration whose SPS/PPS and dimensions
    // come from different sessions.
    //
    // The lock is never held across VTCompressionSessionEncodeFrame,
    // CompleteFrames or Invalidate: those can invoke the output callback
    // synchronously on the calling thread, which would deadlock against
    // makeConfiguration().
    private let stateLock = NSLock()
    private var session: VTCompressionSession?
    private var dimensions = CMVideoDimensions(width: 0, height: 0)
    private var currentOrientation: UInt32 = 1
    private var forceNextKeyFrame = true

    // Only ever touched on ReplayKit's sample thread, so deliberately unguarded.
    private var lastAcceptedPresentationTime = CMTime.invalid
    private var frameCounter: Int64 = 0
    private var consecutiveEncodeFailures = 0
    private var didReportFailure = false

    init(quality: StreamQuality) {
        self.quality = quality
    }

    func encode(_ sampleBuffer: CMSampleBuffer, orientation: UInt32) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = Int32(CVPixelBufferGetWidth(imageBuffer))
        let height = Int32(CVPixelBufferGetHeight(imageBuffer))
        guard width > 0, height > 0 else { return }
        let target = quality.encodedDimensions(sourceWidth: width, sourceHeight: height)

        stateLock.lock()
        let needsRebuild = session == nil
            || dimensions.width != target.width
            || dimensions.height != target.height
        stateLock.unlock()

        if needsRebuild {
            rebuild(width: target.width, height: target.height)
        }

        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        // A local strong reference keeps the session alive for this call even if
        // broadcastFinished() invalidates it concurrently; EncodeFrame then
        // returns an error rather than using freed memory.
        guard let activeSession else { return }

        let incomingPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let targetFrameDuration = CMTime(value: 1, timescale: quality.framesPerSecond)
        // ReplayKit timestamps have small scheduling jitter. A strict 1 / FPS
        // comparison can reject every other nominal 60 Hz sample when it lands
        // a fraction early, so admit frames within ten percent of the target.
        let minimumAcceptedDelta = CMTime(
            value: 9,
            timescale: quality.framesPerSecond * 10
        )
        if lastAcceptedPresentationTime.isValid,
           incomingPTS.isValid,
           CMTimeCompare(
               CMTimeSubtract(incomingPTS, lastAcceptedPresentationTime),
               minimumAcceptedDelta
           ) < 0 {
            return
        }

        stateLock.lock()
        currentOrientation = orientation
        stateLock.unlock()

        let presentationTime: CMTime
        if incomingPTS.isValid {
            presentationTime = incomingPTS
            lastAcceptedPresentationTime = incomingPTS
        } else {
            presentationTime = CMTime(value: frameCounter, timescale: quality.framesPerSecond)
            frameCounter += 1
        }

        // Consume the flag in one critical section, then build the properties
        // dictionary outside it. Clearing unconditionally is equivalent: the flag
        // is only ever set when a key frame is wanted, and this call serves it.
        stateLock.lock()
        let shouldForceKeyFrame = forceNextKeyFrame
        forceNextKeyFrame = false
        stateLock.unlock()

        var properties: CFDictionary?
        if shouldForceKeyFrame {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        var infoFlags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            activeSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTime,
            duration: targetFrameDuration,
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if status != noErr {
            stateLock.lock()
            forceNextKeyFrame = true
            stateLock.unlock()
            consecutiveEncodeFailures += 1
            if consecutiveEncodeFailures >= 3 {
                reportFailure("The H.264 encoder rejected captured frames (VideoToolbox \(status)).")
            }
        } else {
            consecutiveEncodeFailures = 0
        }
    }

    func requestKeyFrame() {
        stateLock.lock()
        forceNextKeyFrame = true
        stateLock.unlock()
    }

    func invalidate() {
        // Detach the session before draining it. CompleteFrames can deliver
        // pending frames through the output callback on this thread, and that
        // path takes stateLock, so the lock must already be released.
        stateLock.lock()
        let expiring = session
        session = nil
        stateLock.unlock()

        guard let expiring else { return }
        VTCompressionSessionCompleteFrames(expiring, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(expiring)
    }

    private func rebuild(width: Int32, height: Int32) {
        invalidate()

        // Publish the new dimensions only after the old session is fully drained
        // by invalidate(), so any frame flushed from it still reports the size it
        // was actually encoded at.
        stateLock.lock()
        dimensions = CMVideoDimensions(width: width, height: height)
        forceNextKeyFrame = true
        stateLock.unlock()

        lastAcceptedPresentationTime = .invalid
        frameCounter = 0
        consecutiveEncodeFailures = 0

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: Self.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            reportFailure("The H.264 encoder could not start (VideoToolbox \(status)).")
            return
        }

        set(created, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // Baseline profile has neither CABAC nor the 8x8 transform, so it spends
        // roughly 10-15 percent more bits for the same picture. Every decoder in
        // this project handles High: WebCodecs derives its codec string from the
        // SPS bytes, and CMVideoFormatDescriptionCreateFromH264ParameterSets is
        // profile-agnostic. Frame reordering stays off below, so High adds no
        // B-frames and no latency — only efficiency.
        set(created, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        // This was previously true, which asks VideoToolbox to trade picture
        // quality for encode speed on every frame. RealTime above already
        // constrains latency; this only degraded the image.
        set(created, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanFalse)
        set(created, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(created, kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        set(created, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: quality.framesPerSecond))
        // New viewers and orientation changes already request an immediate key
        // frame. A forced IDR every half-second only creates bitrate/CPU bursts
        // that Safari presents as periodic freezes, especially at 60 FPS.
        set(created, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: max(1, quality.framesPerSecond * 2)))
        set(created, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2.0))
        let pixelTransferProperties: [CFString: Any] = [
            kVTPixelTransferPropertyKey_RealTime: true,
            kVTPixelTransferPropertyKey_ScalingMode: kVTScalingMode_Normal
        ]
        set(
            created,
            kVTCompressionPropertyKey_PixelTransferProperties,
            pixelTransferProperties as CFDictionary
        )

        let bitRate = quality.bitRate(width: width, height: height)
        set(created, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitRate))
        // DataRateLimits is a hard ceiling, not a target. Setting it to exactly
        // the average bit rate over a one-second window leaves the encoder no
        // headroom for a busy scene, so it crushes quantisation the moment the
        // picture moves. Allow a 1.5x burst and let AverageBitRate govern the
        // steady state.
        set(
            created,
            kVTCompressionPropertyKey_DataRateLimits,
            [
                NSNumber(value: Int(Double(bitRate) * 1.5 / 8.0)),
                NSNumber(value: 1)
            ] as CFArray
        )
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(created)
        if prepareStatus != noErr {
            // Not yet published, so tear down this session directly rather than
            // going through invalidate(), which now only handles the live one.
            VTCompressionSessionInvalidate(created)
            reportFailure("The H.264 encoder could not prepare (VideoToolbox \(prepareStatus)).")
            return
        }

        // Publish only once fully configured and prepared. encode() must never
        // observe a session that is still missing its profile or bit rate.
        stateLock.lock()
        session = created
        stateLock.unlock()
    }

    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) {
        VTSessionSetProperty(session, key: key, value: value)
    }

    private func handle(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var isKeyFrame = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0 {
            let rawDictionary = CFArrayGetValueAtIndex(attachments, 0)
            let dictionary = unsafeBitCast(rawDictionary, to: CFDictionary.self)
            isKeyFrame = !CFDictionaryContainsKey(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            )
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var encoded = Data(count: length)
        let copyStatus = encoded.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        var videoConfiguration: VideoConfiguration?
        if isKeyFrame, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            videoConfiguration = makeConfiguration(from: formatDescription)
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampMicroseconds: Int64
        if presentationTime.isValid {
            timestampMicroseconds = max(
                0,
                Int64((CMTimeGetSeconds(presentationTime) * 1_000_000).rounded())
            )
        } else {
            timestampMicroseconds = 0
        }
        onFrame?(
            EncodedFrame(
                data: encoded,
                isKeyFrame: isKeyFrame,
                configuration: videoConfiguration,
                timestampMicroseconds: timestampMicroseconds
            )
        )
    }

    private func reportFailure(_ message: String) {
        guard !didReportFailure else { return }
        didReportFailure = true
        onFailure?(message)
    }

    private func makeConfiguration(from format: CMFormatDescription) -> VideoConfiguration? {
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var spsCount = 0
        var nalHeaderLength: Int32 = 0
        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )

        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        guard spsStatus == noErr,
              ppsStatus == noErr,
              let spsPointer,
              let ppsPointer else { return nil }

        // This runs on VideoToolbox's callback thread while encode() may be
        // writing on ReplayKit's. Read both fields in one critical section so a
        // key frame cannot advertise the dimensions of one session alongside the
        // orientation of another, which the decoder would reject or mis-render.
        stateLock.lock()
        let encodedDimensions = dimensions
        let encodedOrientation = currentOrientation
        stateLock.unlock()

        return VideoConfiguration(
            width: encodedDimensions.width,
            height: encodedDimensions.height,
            orientation: encodedOrientation,
            sps: Data(bytes: spsPointer, count: spsSize),
            pps: Data(bytes: ppsPointer, count: ppsSize),
            nalUnitHeaderLength: nalHeaderLength,
            nominalFrameRate: quality.framesPerSecond
        )
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard let refcon else { return }
        let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.handle(status: status, sampleBuffer: sampleBuffer)
    }

    deinit {
        invalidate()
    }
}
