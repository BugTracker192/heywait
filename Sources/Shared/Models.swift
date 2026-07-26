import CoreMedia
import Foundation

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
}

struct StreamErrorPayload: Codable, Equatable {
    let message: String
}

enum StreamQuality: String, CaseIterable, Codable {
    case balanced
    case sharp
    case dataSaver

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .sharp: return "Sharp"
        case .dataSaver: return "Data Saver"
        }
    }

    var framesPerSecond: Int32 {
        switch self {
        case .balanced: return 30
        case .sharp: return 30
        case .dataSaver: return 20
        }
    }

    var maximumEncodedDimension: Int32 {
        switch self {
        case .balanced: return 1_440
        case .sharp: return 1_920
        case .dataSaver: return 960
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

        let scale = Double(maximumEncodedDimension) / Double(longestSide)
        return CMVideoDimensions(
            width: evenDimension(Int32(Double(sourceWidth) * scale)),
            height: evenDimension(Int32(Double(sourceHeight) * scale))
        )
    }

    func bitRate(width: Int32, height: Int32) -> Int {
        let pixels = max(1, Int(width) * Int(height))
        let bitsPerPixel: Double
        switch self {
        case .balanced: bitsPerPixel = 0.085
        case .sharp: bitsPerPixel = 0.14
        case .dataSaver: bitsPerPixel = 0.045
        }
        return min(12_000_000, max(1_200_000, Int(Double(pixels) * Double(framesPerSecond) * bitsPerPixel)))
    }

    private func evenDimension(_ value: Int32) -> Int32 {
        max(2, (value / 2) * 2)
    }
}
