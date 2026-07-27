import Foundation

enum BrowserH264Wire {
    private enum PacketType: UInt8 {
        case configuration = 0
        case keyFrame = 1
        case deltaFrame = 2
    }

    static func configurationPacket(_ configuration: VideoConfiguration) -> Data {
        var payload = Data()
        payload.appendUInt32(UInt32(bitPattern: configuration.width))
        payload.appendUInt32(UInt32(bitPattern: configuration.height))
        payload.appendUInt32(configuration.orientation)
        payload.append(UInt8(configuration.effectiveNALUnitHeaderLength))
        payload.appendUInt32(UInt32(configuration.sps.count))
        payload.append(configuration.sps)
        payload.appendUInt32(UInt32(configuration.pps.count))
        payload.append(configuration.pps)
        return packet(type: .configuration, timestampMicroseconds: 0, payload: payload)
    }

    static func framePacket(_ frame: H264Encoder.EncodedFrame) -> Data {
        packet(
            type: frame.isKeyFrame ? .keyFrame : .deltaFrame,
            timestampMicroseconds: UInt64(max(0, frame.timestampMicroseconds)),
            payload: frame.data
        )
    }

    static func chunk(_ payload: Data) -> Data {
        var result = Data(String(payload.count, radix: 16).utf8)
        result.append(Data("\r\n".utf8))
        result.append(payload)
        result.append(Data("\r\n".utf8))
        return result
    }

    private static func packet(
        type: PacketType,
        timestampMicroseconds: UInt64,
        payload: Data
    ) -> Data {
        var result = Data()
        result.append(type.rawValue)
        result.appendUInt64(timestampMicroseconds)
        result.appendUInt32(UInt32(payload.count))
        result.append(payload)
        return result
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
