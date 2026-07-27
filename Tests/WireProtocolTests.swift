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

    func testSequentialPacketsAfterParserDrainsItsBuffer() throws {
        let codec = SecurePacketCodec(pairingCode: "2345-6789-ABCD-EFGH")
        let challenge = try codec.encode(
            kind: .challenge,
            sequence: 1,
            payload: Data(repeating: 0xA5, count: 32)
        )
        let acknowledgement = try codec.encode(
            kind: .helloAcknowledgement,
            sequence: 2,
            payload: Data("receiver".utf8)
        )

        let parser = PacketStreamParser()
        let firstPackets = try parser.append(challenge, using: codec)
        let secondPackets = try parser.append(acknowledgement, using: codec)

        XCTAssertEqual(firstPackets.map(\.kind), [.challenge])
        XCTAssertEqual(secondPackets.map(\.kind), [.helloAcknowledgement])
        XCTAssertEqual(secondPackets[0].payload, Data("receiver".utf8))
    }

    func testCoalescedPacketsAreParsedFromOneNetworkRead() throws {
        let codec = SecurePacketCodec(pairingCode: "2345-6789-ABCD-EFGH")
        let first = try codec.encode(kind: .heartbeat, sequence: 10)
        let second = try codec.encode(
            kind: .orientation,
            sequence: 11,
            payload: Data([0, 0, 0, 6])
        )

        var coalesced = first
        coalesced.append(second)
        let packets = try PacketStreamParser().append(coalesced, using: codec)

        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets.map(\.kind), [.heartbeat, .orientation])
        XCTAssertEqual(packets.map(\.sequence), [10, 11])
        XCTAssertEqual(packets[1].payload, Data([0, 0, 0, 6]))
    }

    func testMultiplePacketsAcrossArbitrarySingleByteChunks() throws {
        let codec = SecurePacketCodec(pairingCode: "2345-6789-ABCD-EFGH")
        let expected = try (0..<4).map { index in
            try codec.encode(
                kind: .heartbeat,
                sequence: UInt64(index + 1),
                payload: Data([UInt8(index)])
            )
        }
        let stream = expected.reduce(into: Data()) { $0.append($1) }
        let parser = PacketStreamParser()
        var packets: [WirePacket] = []

        for byte in stream {
            packets.append(contentsOf: try parser.append(Data([byte]), using: codec))
        }

        XCTAssertEqual(packets.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(packets.map(\.payload), [Data([0]), Data([1]), Data([2]), Data([3])])
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
            pps: Data([4, 5]),
            nalUnitHeaderLength: 4,
            nominalFrameRate: 30
        )
        let restored = try JSONDecoder().decode(
            VideoConfiguration.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(restored, original)
    }

    func testVideoConfigurationDecodesLegacyPayload() throws {
        let legacyJSON = """
        {
          "width": 1170,
          "height": 2532,
          "orientation": 1,
          "sps": "AQID",
          "pps": "BAU="
        }
        """
        let restored = try JSONDecoder().decode(
            VideoConfiguration.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertNil(restored.nalUnitHeaderLength)
        XCTAssertNil(restored.nominalFrameRate)
        XCTAssertEqual(restored.effectiveNALUnitHeaderLength, 4)
        XCTAssertEqual(restored.effectiveFrameRate, 30)
    }

    func testVideoConfigurationRejectsInvalidPresentationMetadata() {
        let configuration = VideoConfiguration(
            width: 1170,
            height: 2532,
            orientation: 1,
            sps: Data([1]),
            pps: Data([2]),
            nalUnitHeaderLength: 3,
            nominalFrameRate: 0
        )

        XCTAssertEqual(configuration.effectiveNALUnitHeaderLength, 4)
        XCTAssertEqual(configuration.effectiveFrameRate, 30)
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

    func testStreamQualityFrameRateTargets() {
        XCTAssertEqual(StreamQuality.balanced.framesPerSecond, 60)
        XCTAssertEqual(StreamQuality.sharp.framesPerSecond, 60)
        XCTAssertEqual(StreamQuality.dataSaver.framesPerSecond, 30)
        XCTAssertEqual(StreamQuality.balanced.browserFramesPerSecond, 24)
        XCTAssertEqual(StreamQuality.sharp.browserFramesPerSecond, 30)
        XCTAssertEqual(StreamQuality.dataSaver.browserFramesPerSecond, 15)
    }

    func testTransportWindowCoversQuarterSecondAtTargetFrameRate() {
        let quarterSecondOfFrames = Int(AppConstants.preferredFramesPerSecond / 4)
        XCTAssertGreaterThanOrEqual(
            AppConstants.maximumOutstandingVideoFrames,
            quarterSecondOfFrames
        )
        XCTAssertGreaterThan(
            AppConstants.maximumOutstandingVideoFrames,
            AppConstants.maximumInFlightNetworkSends
        )
    }

    func testPictureInPictureRequiresExplicitUserAction() {
        XCTAssertFalse(AppConstants.allowsAutomaticPictureInPicture)
    }

    func testReceiverBackgroundGraceIsBoundedToOneMinute() {
        XCTAssertEqual(AppConstants.receiverBackgroundGraceSeconds, 60)
    }

    func testNativeAndBrowserDestinationReadinessAreIndependent() {
        let native = SenderConfiguration(
            deliveryMode: .nativeReceiver,
            receiverServiceName: "ScreenShare-12345678",
            pairingCode: "2345-6789-ABCD-EFGH",
            quality: .balanced,
            browserAccessKey: ""
        )
        let browser = SenderConfiguration(
            deliveryMode: .browser,
            receiverServiceName: "",
            pairingCode: "",
            quality: .balanced,
            browserAccessKey: "2345-6789-ABCD-EFGH"
        )

        XCTAssertTrue(native.isReady)
        XCTAssertTrue(browser.isReady)
    }

    func testBrowserLinkUsesFixedLocalPortAndNormalizedPrivateKey() throws {
        let url = LocalBrowserLink.url(
            host: "192.168.1.23",
            accessKey: "2345-6789-ABCD-EFGH"
        )

        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host, "192.168.1.23")
        XCTAssertEqual(url?.port, Int(AppConstants.browserViewerPort))
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(url), resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "k" })?
                .value,
            "23456789ABCDEFGH"
        )
    }

    func testRemoteVideoGeometryFollowsIntendedDisplayAspect() {
        XCTAssertEqual(
            ReceiverOrientationCoordinator.interfaceOrientations(
                encodedWidth: 664,
                encodedHeight: 1_440,
                videoOrientation: 1
            ),
            .portrait
        )
        XCTAssertEqual(
            ReceiverOrientationCoordinator.interfaceOrientations(
                encodedWidth: 1_440,
                encodedHeight: 664,
                videoOrientation: 3
            ),
            .landscape
        )
        XCTAssertEqual(
            ReceiverOrientationCoordinator.interfaceOrientations(
                encodedWidth: 664,
                encodedHeight: 1_440,
                videoOrientation: 6
            ),
            .landscape
        )
        XCTAssertEqual(
            ReceiverOrientationCoordinator.interfaceOrientations(
                encodedWidth: 1_440,
                encodedHeight: 664,
                videoOrientation: 8
            ),
            .portrait
        )
    }
}
