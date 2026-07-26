import AVFoundation
import Foundation
import VideoToolbox

final class H264Encoder {
    struct EncodedFrame {
        let data: Data
        let isKeyFrame: Bool
        let configuration: VideoConfiguration?
    }

    var onFrame: ((EncodedFrame) -> Void)?

    private let quality: StreamQuality
    private var session: VTCompressionSession?
    private var dimensions = CMVideoDimensions(width: 0, height: 0)
    private var currentOrientation: UInt32 = 1
    private var forceNextKeyFrame = true
    private var lastAcceptedPresentationTime = CMTime.invalid
    private var frameCounter: Int64 = 0

    init(quality: StreamQuality) {
        self.quality = quality
    }

    func encode(_ sampleBuffer: CMSampleBuffer, orientation: UInt32) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = Int32(CVPixelBufferGetWidth(imageBuffer))
        let height = Int32(CVPixelBufferGetHeight(imageBuffer))
        guard width > 0, height > 0 else { return }

        if session == nil || dimensions.width != width || dimensions.height != height {
            rebuild(width: width, height: height)
        }
        guard let session else { return }

        let incomingPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let minimumDelta = CMTime(value: 1, timescale: quality.framesPerSecond)
        if lastAcceptedPresentationTime.isValid,
           incomingPTS.isValid,
           CMTimeCompare(CMTimeSubtract(incomingPTS, lastAcceptedPresentationTime), minimumDelta) < 0 {
            return
        }

        currentOrientation = orientation
        let presentationTime: CMTime
        if incomingPTS.isValid {
            presentationTime = incomingPTS
            lastAcceptedPresentationTime = incomingPTS
        } else {
            presentationTime = CMTime(value: frameCounter, timescale: quality.framesPerSecond)
            frameCounter += 1
        }

        var properties: CFDictionary?
        if forceNextKeyFrame {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceNextKeyFrame = false
        }

        var infoFlags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTime,
            duration: minimumDelta,
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if status != noErr {
            forceNextKeyFrame = true
        }
    }

    func requestKeyFrame() {
        forceNextKeyFrame = true
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func rebuild(width: Int32, height: Int32) {
        invalidate()
        dimensions = CMVideoDimensions(width: width, height: height)
        lastAcceptedPresentationTime = .invalid
        frameCounter = 0
        forceNextKeyFrame = true

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
        guard status == noErr, let created else { return }
        session = created

        set(created, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(created, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(created, kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        set(created, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        set(created, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: quality.framesPerSecond))
        set(created, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: AppConstants.keyFrameInterval))
        set(created, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1))

        let bitRate = quality.bitRate(width: width, height: height)
        set(created, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitRate))
        set(
            created,
            kVTCompressionPropertyKey_DataRateLimits,
            [NSNumber(value: bitRate / 8), NSNumber(value: 1)] as CFArray
        )
        VTCompressionSessionPrepareToEncodeFrames(created)
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
        onFrame?(EncodedFrame(data: encoded, isKeyFrame: isKeyFrame, configuration: videoConfiguration))
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

        return VideoConfiguration(
            width: dimensions.width,
            height: dimensions.height,
            orientation: currentOrientation,
            sps: Data(bytes: spsPointer, count: spsSize),
            pps: Data(bytes: ppsPointer, count: ppsSize)
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
