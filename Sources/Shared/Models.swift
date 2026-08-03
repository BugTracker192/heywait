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

    var maximumEncodedDimension: Int32 {
        switch self {
        case .balanced: return 960
        case .sharp: return 1_080
        case .ultra: return 1_440
        case .dataSaver: return 540
        }
    }

    func encodedDimensions(sourceWidth: Int32, sourceHeight: Int32) -> CMVideoDimensions {
        guard sourceWidth > 0, sourceHeight > 0 else {
            return CMVideoDimensions(width: 0, height: 0)
        }

        let longestSide = max(sourceWidth, sourceHeight)
        guard longestSide > maximumEncodedDimension else {
            return CMVideoDimensions(
                width: evenDimension(sourceWidth),
                height: evenDimension(sourceHeight)
            )
        }

        if sourceWidth >= sourceHeight {
            return CMVideoDimensions(
                width: maximumEncodedDimension,
                height: evenDimension(
                    Int32(Int64(sourceHeight) * Int64(maximumEncodedDimension) / Int64(sourceWidth))
                )
            )
        }
        return CMVideoDimensions(
            width: evenDimension(
                Int32(Int64(sourceWidth) * Int64(maximumEncodedDimension) / Int64(sourceHeight))
            ),
            height: maximumEncodedDimension
        )
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
        let ceiling = self == .ultra ? 12_000_000 : 8_000_000
        return min(ceiling, max(800_000, Int(Double(pixels) * Double(framesPerSecond) * bitsPerPixel)))
    }

    private func evenDimension(_ value: Int32) -> Int32 {
        max(2, (value / 2) * 2)
    }
}
