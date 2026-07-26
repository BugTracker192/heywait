import AVFoundation
import CoreMedia
import Foundation
import UIKit

final class VideoRendererView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var orientation: UInt32 = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsCapture = false
        layer.addSublayer(displayLayer)
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
}

final class H264DisplayDecoder {
    private let renderer: VideoRendererView
    private var formatDescription: CMVideoFormatDescription?
    private var currentConfiguration: VideoConfiguration?

    init(renderer: VideoRendererView) {
        self.renderer = renderer
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
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newFormatDescription
                        )
                    }
                }
            }
        }

        guard status == noErr else {
            self.formatDescription = nil
            return
        }
        formatDescription = newFormatDescription
        currentConfiguration = configuration
        renderer.setOrientation(configuration.orientation)
        renderer.flush()
    }

    func updateOrientation(_ orientation: UInt32) {
        renderer.setOrientation(orientation)
    }

    func enqueue(_ data: Data) {
        guard let formatDescription, !data.isEmpty else { return }

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
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return }

        let replaceStatus = data.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return }

        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }
        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )

        let render = { [weak renderer] in
            guard let renderer else { return }
            if renderer.displayLayer.status == .failed || renderer.displayLayer.requiresFlushToResumeDecoding {
                renderer.displayLayer.flush()
            }
            renderer.displayLayer.enqueue(sampleBuffer)
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
        renderer.flush()
    }
}
