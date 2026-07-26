import AVFoundation
import CoreMedia
import Foundation
import UIKit

final class VideoRendererView: UIView {
    private(set) var displayLayer = AVSampleBufferDisplayLayer()
    var onReadyForDisplay: (() -> Void)?
    var onDecodeFailure: ((String) -> Void)?
    var onDisplayLayerChanged: ((AVSampleBufferDisplayLayer) -> Void)?

    private var orientation: UInt32 = 1
    private var readyObservation: NSKeyValueObservation?
    private var decodeFailureObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        installDisplayLayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let isQuarterTurn = [5, 6, 7, 8].contains(orientation)
        let layerSize = isQuarterTurn
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
        displayLayer.bounds = CGRect(origin: .zero, size: layerSize)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.setAffineTransform(transform(for: orientation))
        CATransaction.commit()
    }

    func setOrientation(_ value: UInt32) {
        guard orientation != value else { return }
        orientation = value
        setNeedsLayout()
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }

    func prepareForEnqueue() -> AVSampleBufferDisplayLayer {
        if displayLayer.status == .failed {
            replaceDisplayLayer()
        } else if displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flush()
        }
        return displayLayer
    }

    private func replaceDisplayLayer() {
        removeDisplayLayerObservers()
        displayLayer.removeFromSuperlayer()

        let replacement = AVSampleBufferDisplayLayer()
        displayLayer = replacement
        installDisplayLayer(replacement)
        setNeedsLayout()
        layoutIfNeeded()
        onDisplayLayerChanged?(replacement)
    }

    private func installDisplayLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsCapture = false
        layer.addSublayer(displayLayer)

        if #available(iOS 17.4, *) {
            readyObservation = displayLayer.observe(
                \.isReadyForDisplay,
                options: [.initial, .new]
            ) { [weak self, weak displayLayer] _, _ in
                guard displayLayer?.isReadyForDisplay == true else { return }
                DispatchQueue.main.async {
                    self?.onReadyForDisplay?()
                }
            }
        } else {
            readyObservation = displayLayer.observe(
                \.status,
                options: [.initial, .new]
            ) { [weak self, weak displayLayer] _, _ in
                guard displayLayer?.status == .rendering else { return }
                DispatchQueue.main.async {
                    self?.onReadyForDisplay?()
                }
            }
        }

        decodeFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerFailedToDecode,
            object: displayLayer,
            queue: .main
        ) { [weak self, weak displayLayer] notification in
            let notificationError = notification.userInfo?[
                AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey
            ] as? Error
            let message = notificationError?.localizedDescription
                ?? displayLayer?.error?.localizedDescription
                ?? "The H.264 frame could not be decoded."
            self?.onDecodeFailure?(message)
        }
    }

    private func removeDisplayLayerObservers() {
        readyObservation?.invalidate()
        readyObservation = nil
        if let decodeFailureObserver {
            NotificationCenter.default.removeObserver(decodeFailureObserver)
            self.decodeFailureObserver = nil
        }
    }

    private func transform(for orientation: UInt32) -> CGAffineTransform {
        switch orientation {
        case 3, 4:
            return CGAffineTransform(rotationAngle: .pi)
        case 5, 6:
            return CGAffineTransform(rotationAngle: .pi / 2)
        case 7, 8:
            return CGAffineTransform(rotationAngle: -.pi / 2)
        default:
            return .identity
        }
    }

    deinit {
        removeDisplayLayerObservers()
    }
}

final class H264DisplayDecoder {
    var onFailure: ((String) -> Void)?

    private let renderer: VideoRendererView
    private var formatDescription: CMVideoFormatDescription?
    private var currentConfiguration: VideoConfiguration?
    private var nextPresentationTime = CMTime.zero
    private var frameDuration = CMTime(value: 1, timescale: 30)

    init(renderer: VideoRendererView) {
        self.renderer = renderer
        renderer.onDecodeFailure = { [weak self] message in
            self?.onFailure?("Video decode failed: \(message)")
        }
    }

    func configure(_ configuration: VideoConfiguration) {
        guard configuration != currentConfiguration else { return }

        var newFormatDescription: CMVideoFormatDescription?
        let status: OSStatus = configuration.sps.withUnsafeBytes { spsBytes in
            configuration.pps.withUnsafeBytes { ppsBytes in
                guard let sps = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let pps = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                let pointers: [UnsafePointer<UInt8>] = [sps, pps]
                let sizes = [configuration.sps.count, configuration.pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: configuration.effectiveNALUnitHeaderLength,
                            formatDescriptionOut: &newFormatDescription
                        )
                    }
                }
            }
        }

        guard status == noErr else {
            formatDescription = nil
            currentConfiguration = nil
            onFailure?("Video format was rejected by Core Media (\(status)).")
            return
        }
        formatDescription = newFormatDescription
        currentConfiguration = configuration
        nextPresentationTime = .zero
        frameDuration = CMTime(value: 1, timescale: configuration.effectiveFrameRate)
        renderer.setOrientation(configuration.orientation)
        renderer.flush()
    }

    func updateOrientation(_ orientation: UInt32) {
        renderer.setOrientation(orientation)
    }

    func enqueue(_ data: Data, isKeyFrame: Bool) {
        guard let formatDescription else {
            onFailure?("Waiting for the H.264 video configuration.")
            return
        }
        guard !data.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else {
            onFailure?("Could not allocate a video buffer (\(createStatus)).")
            return
        }

        let replaceStatus = data.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            onFailure?("Could not copy a video frame (\(replaceStatus)).")
            return
        }

        var sampleSize = data.count
        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: nextPresentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            onFailure?("Could not create a video sample (\(sampleStatus)).")
            return
        }
        nextPresentationTime = CMTimeAdd(nextPresentationTime, frameDuration)
        setSampleAttachments(on: sampleBuffer, isKeyFrame: isKeyFrame)

        let render = { [weak renderer] in
            guard let renderer else { return }
            renderer.prepareForEnqueue().enqueue(sampleBuffer)
        }
        if Thread.isMainThread {
            render()
        } else {
            DispatchQueue.main.async(execute: render)
        }
    }

    func reset() {
        formatDescription = nil
        currentConfiguration = nil
        nextPresentationTime = .zero
        renderer.flush()
    }

    private func setSampleAttachments(on sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else {
            return
        }

        let rawDictionary = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(rawDictionary, to: CFMutableDictionary.self)
        set(
            kCMSampleAttachmentKey_DisplayImmediately,
            to: kCFBooleanTrue,
            in: dictionary
        )
        set(
            kCMSampleAttachmentKey_NotSync,
            to: isKeyFrame ? kCFBooleanFalse : kCFBooleanTrue,
            in: dictionary
        )
        set(
            kCMSampleAttachmentKey_DependsOnOthers,
            to: isKeyFrame ? kCFBooleanFalse : kCFBooleanTrue,
            in: dictionary
        )
    }

    private func set(_ key: CFString, to value: CFBoolean, in dictionary: CFMutableDictionary) {
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(value).toOpaque()
        )
    }
}
