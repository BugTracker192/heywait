import CoreMedia
import Foundation

enum DeliveryMode: String, CaseIterable, Codable {
    case nativeReceiver
    case browser

    var title: String {
        switch self {
        case .nativeReceiver: return "Receiver App"
        case .browser: return "Browser"
        }
    }
}

struct HelloPayload: Codable, Equatable {
    let protocolVersion: Int
    let sessionID: UUID
    let senderName: String
    let sentAtMilliseconds: UInt64
    let receiverChallenge: Data
}

struct HelloAcknowledgement: Codable, Equatable {
    let protocolVersion: Int
    let receiverName: String
}

struct VideoConfiguration: Codable, Equatable {
    let width: Int32
    let height: Int32
    let orientation: UInt32
    let sps: Data
    let pps: Data
    let nalUnitHeaderLength: Int32?
    let nominalFrameRate: Int32?

    var effectiveNALUnitHeaderLength: Int32 {
        guard let nalUnitHeaderLength, [1, 2, 4].contains(nalUnitHeaderLength) else {
            return 4
        }
        return nalUnitHeaderLength
    }

    var effectiveFrameRate: Int32 {
        guard let nominalFrameRate, (1...120).contains(nominalFrameRate) else {
            return 30
        }
        return nominalFrameRate
    }

    // True when two configurations describe the same decoder setup. Orientation
    // travels in this payload but is a presentation property, not a decoder one:
    // it is applied as a layer transform. The browser viewer already draws this
    // line with its `decoderSignature`; comparing whole configurations instead
    // made every rotation rebuild the format description and blank the picture.
    func describesSameDecoderState(as other: VideoConfiguration) -> Bool {
        width == other.width
            && height == other.height
            && sps == other.sps
            && pps == other.pps
            && effectiveNALUnitHeaderLength == other.effectiveNALUnitHeaderLength
            && effectiveFrameRate == other.effectiveFrameRate
    }
}

struct StreamErrorPayload: Codable, Equatable {
    let message: String
}

enum StreamQuality: String, CaseIterable, Codable {
    case balanced
    case sharp
    case ultra
    case dataSaver

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .sharp: return "Sharp"
        case .ultra: return "Ultra"
        case .dataSaver: return "Fast"
        }
    }

    var framesPerSecond: Int32 {
        switch self {
        case .balanced: return 60
        case .sharp: return 60
        case .ultra: return 60
        case .dataSaver: return 60
        }
    }

    var browserFramesPerSecond: Int32 {
        switch self {
        case .balanced: return 24
        case .sharp: return 30
        // MJPEG is only a compatibility fallback. Ultra's primary H.264
        // path remains 60 FPS; attempting 1440p JPEG compression at 60 FPS
        // inside ReplayKit would increase stalls rather than motion quality.
        case .ultra: return 30
        case .dataSaver: return 30
        }
    }

    // Deliberately bounds the LONGER edge, unlike `maximumEncodedShortEdge`.
    // The MJPEG fallback sends whole intra-coded frames, so matching the H.264
    // short-edge bound would cost roughly 100 Mbps at 30 FPS. Keep this path
    // small: it only runs on iOS below 16.4 or when a decoder genuinely fails.
    var browserMaximumDimension: CGFloat {
        switch self {
        case .balanced: return 960
        case .sharp: return 1_080
        case .ultra: return 1_440
        case .dataSaver: return 540
        }
    }

    var browserJPEGQuality: CGFloat {
        switch self {
        case .balanced: return 0.68
        case .sharp: return 0.78
        case .ultra: return 0.84
        case .dataSaver: return 0.55
        }
    }

    // Bound on the SHORTER edge of the encoded frame.
    //
    // This previously bounded the longer edge, which made every label wrong.
    // ReplayKit delivers a portrait-shaped buffer (1170x2532 on a 6.1" phone),
    // so a 1080 long-edge cap scaled it to 498x1080 — a stream carrying 498
    // lines across the width of a landscape viewer. Bounding the shorter edge
    // makes the number describe the actual line count, and sources already at
    // or below the bound pass through untouched rather than being upscaled.
    var maximumEncodedShortEdge: Int32 {
        switch self {
        case .balanced: return 720
        case .sharp: return 1_080
        case .ultra: return 1_440
        case .dataSaver: return 480
        }
    }

    func encodedDimensions(sourceWidth: Int32, sourceHeight: Int32) -> CMVideoDimensions {
        guard sourceWidth > 0, sourceHeight > 0 else {
            return CMVideoDimensions(width: 0, height: 0)
        }

        let bound = maximumEncodedShortEdge
        let shortestSide = min(sourceWidth, sourceHeight)
        guard shortestSide > bound else {
            return CMVideoDimensions(
                width: evenDimension(sourceWidth),
                height: evenDimension(sourceHeight)
            )
        }

        if sourceWidth <= sourceHeight {
            return CMVideoDimensions(
                width: bound,
                height: evenDimension(
                    Int32(Int64(sourceHeight) * Int64(bound) / Int64(sourceWidth))
                )
            )
        }
        return CMVideoDimensions(
            width: evenDimension(
                Int32(Int64(sourceWidth) * Int64(bound) / Int64(sourceHeight))
            ),
            height: bound
        )
    }

    // Ceiling for the encoded bit rate.
    //
    // These must scale with `maximumEncodedShortEdge`. The previous 8 Mbps cap
    // was ample for a 498x1080 stream but starves a 1080x2336 one: 8 Mbps over
    // 2.5 megapixels at 60 Hz is 0.05 bits per pixel, which reads as blocking
    // and smearing rather than detail. Raising resolution without raising this
    // ceiling makes the picture worse, not better.
    var maximumBitRate: Int {
        switch self {
        case .balanced: return 12_000_000
        case .sharp: return 24_000_000
        case .ultra: return 32_000_000
        case .dataSaver: return 6_000_000
        }
    }

    func bitRate(width: Int32, height: Int32) -> Int {
        let pixels = max(1, Int(width) * Int(height))
        let bitsPerPixel: Double
        switch self {
        case .balanced: bitsPerPixel = 0.10
        case .sharp: bitsPerPixel = 0.14
        case .ultra: bitsPerPixel = 0.16
        case .dataSaver: bitsPerPixel = 0.09
        }
        return min(
            maximumBitRate,
            max(800_000, Int(Double(pixels) * Double(framesPerSecond) * bitsPerPixel))
        )
    }

    private func evenDimension(_ value: Int32) -> Int32 {
        max(2, (value / 2) * 2)
    }
}
