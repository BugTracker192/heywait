import CoreImage
import CoreMedia
import Foundation

final class BrowserJPEGEncoder {
    var onFrame: ((Data) -> Void)?

    private let quality: StreamQuality
    private let context = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: true
    ])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let queue = DispatchQueue(label: "dev.screenshare.browser.jpeg", qos: .userInteractive)
    private let stateLock = NSLock()
    private var isEncoding = false
    private var lastAcceptedPresentationTime = CMTime.invalid

    init(quality: StreamQuality) {
        self.quality = quality
    }

    func encode(_ sampleBuffer: CMSampleBuffer, orientation: UInt32) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        stateLock.lock()
        defer { stateLock.unlock() }

        guard !isEncoding else { return }
        if lastAcceptedPresentationTime.isValid, presentationTime.isValid {
            let minimumDelta = CMTime(
                value: 9,
                timescale: quality.browserFramesPerSecond * 10
            )
            guard CMTimeCompare(
                CMTimeSubtract(presentationTime, lastAcceptedPresentationTime),
                minimumDelta
            ) >= 0 else {
                return
            }
        }

        isEncoding = true
        if presentationTime.isValid {
            lastAcceptedPresentationTime = presentationTime
        }

        queue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                   let jpeg = self.makeJPEG(from: imageBuffer, orientation: orientation) {
                    self.onFrame?(jpeg)
                }
                self.stateLock.lock()
                self.isEncoding = false
                self.stateLock.unlock()
            }
        }
    }

    private func makeJPEG(from imageBuffer: CVPixelBuffer, orientation: UInt32) -> Data? {
        var image = CIImage(cvPixelBuffer: imageBuffer)
        if (1...8).contains(orientation) {
            image = image.oriented(forExifOrientation: Int32(orientation))
        }

        let extent = image.extent
        let longestSide = max(extent.width, extent.height)
        if longestSide > quality.browserMaximumDimension {
            let scale = quality.browserMaximumDimension / longestSide
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let translated = image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            )
        )
        return context.jpegRepresentation(
            of: translated,
            colorSpace: colorSpace,
            options: [.lossyCompressionQuality: quality.browserJPEGQuality]
        )
    }
}
