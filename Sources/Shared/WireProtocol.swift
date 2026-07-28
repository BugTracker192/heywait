import CryptoKit
import Foundation

enum PacketKind: UInt8 {
    case challenge = 0
    case hello = 1
    case helloAcknowledgement = 2
    case videoConfiguration = 16
    case videoFrame = 17
    case orientation = 18
    case audioPCM = 19
    case heartbeat = 32
    case streamError = 255
}

struct PacketFlags: OptionSet, Equatable {
    let rawValue: UInt16

    static let keyFrame = PacketFlags(rawValue: 1 << 0)
}

struct WirePacket: Equatable {
    let kind: PacketKind
    let flags: PacketFlags
    let sequence: UInt64
    let payload: Data
}

enum WireProtocolError: LocalizedError {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case invalidPacketKind(UInt8)
    case packetTooLarge(Int)
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidMagic: return "The stream packet header is invalid."
        case .unsupportedVersion(let version): return "Unsupported stream protocol version \(version)."
        case .invalidPacketKind(let value): return "Unknown stream packet type \(value)."
        case .packetTooLarge(let size): return "Stream packet is too large (\(size) bytes)."
        case .authenticationFailed: return "The pairing code is incorrect or the packet was modified."
        }
    }
}

private struct WireHeader {
    static let magic = Data([0x53, 0x53, 0x56, 0x31]) // SSV1
    static let byteCount = 20

    let version: UInt8
    let kind: PacketKind
    let flags: PacketFlags
    let sequence: UInt64
    let payloadLength: Int

    var authenticatedData: Data {
        var data = Data()
        data.append(Self.magic)
        data.append(version)
        data.append(kind.rawValue)
        data.appendBigEndian(flags.rawValue)
        data.appendBigEndian(sequence)
        return data
    }

    var encoded: Data {
        var data = authenticatedData
        data.appendBigEndian(UInt32(payloadLength))
        return data
    }

    static func decode(_ data: Data) throws -> WireHeader {
        guard data.count >= byteCount else { throw WireProtocolError.invalidMagic }
        guard Data(data.prefix(4)) == magic else { throw WireProtocolError.invalidMagic }
        let version = data.byte(atOffset: 4)
        guard version == AppConstants.protocolVersion else {
            throw WireProtocolError.unsupportedVersion(version)
        }
        let rawKind = data.byte(atOffset: 5)
        guard let kind = PacketKind(rawValue: rawKind) else {
            throw WireProtocolError.invalidPacketKind(rawKind)
        }
        let flags = PacketFlags(rawValue: data.readUInt16(at: 6))
        let sequence = data.readUInt64(at: 8)
        let payloadLength = Int(data.readUInt32(at: 16))
        guard payloadLength <= AppConstants.maximumPacketBytes else {
            throw WireProtocolError.packetTooLarge(payloadLength)
        }
        return WireHeader(
            version: version,
            kind: kind,
            flags: flags,
            sequence: sequence,
            payloadLength: payloadLength
        )
    }
}

final class SecurePacketCodec {
    private let key: SymmetricKey

    init(pairingCode: String) {
        key = PairingSecret.symmetricKey(for: pairingCode)
    }

    func encode(kind: PacketKind, flags: PacketFlags = [], sequence: UInt64, payload: Data = Data()) throws -> Data {
        let aadHeader = WireHeader(
            version: AppConstants.protocolVersion,
            kind: kind,
            flags: flags,
            sequence: sequence,
            payloadLength: 0
        )
        let sealed = try ChaChaPoly.seal(payload, using: key, authenticating: aadHeader.authenticatedData)
        let combined = sealed.combined
        let header = WireHeader(
            version: AppConstants.protocolVersion,
            kind: kind,
            flags: flags,
            sequence: sequence,
            payloadLength: combined.count
        )
        var result = header.encoded
        result.append(combined)
        return result
    }

    func decode(headerData: Data, encryptedPayload: Data) throws -> WirePacket {
        let header = try WireHeader.decode(headerData)
        do {
            let box = try ChaChaPoly.SealedBox(combined: encryptedPayload)
            let cleartext = try ChaChaPoly.open(box, using: key, authenticating: header.authenticatedData)
            return WirePacket(
                kind: header.kind,
                flags: header.flags,
                sequence: header.sequence,
                payload: cleartext
            )
        } catch {
            throw WireProtocolError.authenticationFailed
        }
    }
}

final class PacketStreamParser {
    private var buffer = Data()

    func append(_ data: Data, using codec: SecurePacketCodec) throws -> [WirePacket] {
        buffer.append(data)
        var packets: [WirePacket] = []

        while buffer.count >= WireHeader.byteCount {
            let headerEnd = buffer.index(buffer.startIndex, offsetBy: WireHeader.byteCount)
            let headerData = Data(buffer[buffer.startIndex..<headerEnd])
            let header = try WireHeader.decode(headerData)
            let totalLength = WireHeader.byteCount + header.payloadLength
            guard buffer.count >= totalLength else { break }

            let packetEnd = buffer.index(buffer.startIndex, offsetBy: totalLength)
            let encryptedPayload = Data(buffer[headerEnd..<packetEnd])
            packets.append(try codec.decode(headerData: headerData, encryptedPayload: encryptedPayload))
            buffer.removeSubrange(buffer.startIndex..<packetEnd)
        }
        return packets
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func byte(atOffset offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func readUInt16(at offset: Int) -> UInt16 {
        (UInt16(byte(atOffset: offset)) << 8) | UInt16(byte(atOffset: offset + 1))
    }

    func readUInt32(at offset: Int) -> UInt32 {
        (UInt32(byte(atOffset: offset)) << 24)
            | (UInt32(byte(atOffset: offset + 1)) << 16)
            | (UInt32(byte(atOffset: offset + 2)) << 8)
            | UInt32(byte(atOffset: offset + 3))
    }

    func readUInt64(at offset: Int) -> UInt64 {
        (UInt64(readUInt32(at: offset)) << 32) | UInt64(readUInt32(at: offset + 4))
    }
}
