import CryptoKit
import XCTest
@testable import ScreenShareReceiver

final class WireProtocolTests: XCTestCase {
    func testPairingCodeRoundTrip() {
        let code = PairingSecret.generate()
        XCTAssertTrue(PairingSecret.isValid(code))
        XCTAssertEqual(PairingSecret.normalize(PairingSecret.format(code)).count, 16)
    }

    func testEncryptedPacketRoundTripAcrossChunks() throws {
        let codec = SecurePacketCodec(pairingCode: "2345-6789-ABCD-EFGH")
        let encoded = try codec.encode(
            kind: .videoFrame,
            flags: .keyFrame,
            sequence: 42,
            payload: Data("frame".utf8)
        )

        let parser = PacketStreamParser()
        let midpoint = encoded.count / 2
        XCTAssertTrue(try parser.append(Data(encoded[..<midpoint]), using: codec).isEmpty)
        let packets = try parser.append(Data(encoded[midpoint...]), using: codec)

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].kind, .videoFrame)
        XCTAssertEqual(packets[0].flags, .keyFrame)
        XCTAssertEqual(packets[0].sequence, 42)
        XCTAssertEqual(packets[0].payload, Data("frame".utf8))
    }

    func testWrongCodeCannotDecrypt() throws {
        let sender = SecurePacketCodec(pairingCode: "2345-6789-ABCD-EFGH")
        let receiver = SecurePacketCodec(pairingCode: "JKLM-NPQR-STUV-WXYZ")
        let encoded = try sender.encode(kind: .heartbeat, sequence: 1)

        XCTAssertThrowsError(try PacketStreamParser().append(encoded, using: receiver))
    }

    func testVideoConfigurationCodableRoundTrip() throws {
        let original = VideoConfiguration(
            width: 1170,
            height: 2532,
            orientation: 1,
            sps: Data([1, 2, 3]),
            pps: Data([4, 5])
        )
        let restored = try JSONDecoder().decode(
            VideoConfiguration.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(restored, original)
    }

    func testStreamQualityBoundsNativePhoneResolution() {
        let balanced = StreamQuality.balanced.encodedDimensions(sourceWidth: 1170, sourceHeight: 2532)
        XCTAssertEqual(balanced.width, 664)
        XCTAssertEqual(balanced.height, 1440)

        let sharp = StreamQuality.sharp.encodedDimensions(sourceWidth: 1170, sourceHeight: 2532)
        XCTAssertEqual(sharp.width, 886)
        XCTAssertEqual(sharp.height, 1920)

        let saver = StreamQuality.dataSaver.encodedDimensions(sourceWidth: 1170, sourceHeight: 2532)
        XCTAssertEqual(saver.width, 442)
        XCTAssertEqual(saver.height, 960)
    }

    func testStreamQualityKeepsSmallEvenResolution() {
        let dimensions = StreamQuality.balanced.encodedDimensions(sourceWidth: 750, sourceHeight: 1334)
        XCTAssertEqual(dimensions.width, 750)
        XCTAssertEqual(dimensions.height, 1334)
    }
}
