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

    func testAudioPCMFrameRoundTrip() throws {
        var samples = Data()
        for value: Float in [0, 0.25, -0.25, 1, -1, 0] {
            var littleEndian = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { samples.append(contentsOf: $0) }
        }
        let original = try AudioPCMFrame(
            format: .float32,
            isInterleaved: true,
            channelCount: 2,
            sampleRate: 48_000,
            frameCount: 3,
            timestampMicroseconds: 123_456,
            samples: samples
        )

        XCTAssertEqual(try AudioPCMFrame(encoded: original.encoded), original)
    }

    func testAudioPCMFrameRejectsTruncatedPayload() throws {
        let frame = try AudioPCMFrame(
            format: .int16,
            isInterleaved: false,
            channelCount: 1,
            sampleRate: 44_100,
            frameCount: 2,
            timestampMicroseconds: 0,
            samples: Data([0, 0, 1, 0])
        )

        XCTAssertThrowsError(try AudioPCMFrame(encoded: Data(frame.encoded.dropLast())))
    }

    func testMicrophoneAudioSurvivesARoundTripAndIsTagged() throws {
        let microphone = try AudioPCMFrame(
            format: .int16,
            isInterleaved: false,
            channelCount: 1,
            sampleRate: 44_100,
            frameCount: 2,
            timestampMicroseconds: 99,
            samples: Data([0, 0, 1, 0]),
            isMicrophone: true
        )

        XCTAssertTrue(microphone.isMicrophone)
        let decoded = try AudioPCMFrame(encoded: microphone.encoded)
        XCTAssertEqual(decoded, microphone)
        XCTAssertTrue(decoded.isMicrophone)
        // Flag bit 1 in header byte 2 carries the source; bit 0 stays interleaving.
        XCTAssertEqual(microphone.encoded[2] & 0b10, 0b10)
        XCTAssertEqual(microphone.encoded[2] & 0b01, 0)
    }

    func testApplicationAudioIsTheDefaultSourceAndSetsNoMicrophoneBit() throws {
        let application = try AudioPCMFrame(
            format: .int16,
            isInterleaved: true,
            channelCount: 1,
            sampleRate: 44_100,
            frameCount: 2,
            timestampMicroseconds: 0,
            samples: Data([0, 0, 1, 0])
        )

        XCTAssertFalse(application.isMicrophone)
        XCTAssertEqual(application.encoded[2] & 0b10, 0)
        XCTAssertFalse(try AudioPCMFrame(encoded: application.encoded).isMicrophone)
    }

    func testInterleavingAndMicrophoneFlagsAreIndependent() throws {
        for interleaved in [true, false] {
            for microphone in [true, false] {
                let frame = try AudioPCMFrame(
                    format: .float32,
                    isInterleaved: interleaved,
                    channelCount: 1,
                    sampleRate: 48_000,
                    frameCount: 1,
                    timestampMicroseconds: 0,
                    samples: Data(count: 4),
                    isMicrophone: microphone
                )
                let decoded = try AudioPCMFrame(encoded: frame.encoded)
                XCTAssertEqual(decoded.isInterleaved, interleaved)
                XCTAssertEqual(decoded.isMicrophone, microphone)
            }
        }
    }

    func testAudioQueueIsStrictlyBounded() {
        XCTAssertGreaterThan(AppConstants.maximumPendingAudioFrames, 0)
        XCTAssertLessThanOrEqual(AppConstants.maximumPendingAudioFrames, 10)
        XCTAssertLessThan(
            AppConstants.maximumAudioFrameBytes,
            AppConstants.maximumPacketBytes
        )
    }

    func testAudioCapableNativeProtocolUsesVersionTwo() {
        XCTAssertEqual(AppConstants.protocolVersion, 2)
    }

    func testPCMNormalizerConvertsInterleavedInt16ToPlanarFloat32() throws {
        // Frames: (L: 0, R: max), (L: min, R: half).
        let interleaved = Data([0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80, 0x00, 0x40])
        let normalized = try XCTUnwrap(LinearPCMNormalizer.planarFloat32(
            buffers: [interleaved],
            sourceFormat: .int16,
            isInterleaved: true,
            isBigEndian: false,
            channelCount: 2,
            frameCount: 2,
            bytesPerFrame: 4
        ))

        XCTAssertEqual(floatSample(in: normalized, at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(floatSample(in: normalized, at: 1), -1, accuracy: 0.0001)
        XCTAssertEqual(
            floatSample(in: normalized, at: 2),
            Float(32_767) / 32_768,
            accuracy: 0.0001
        )
        XCTAssertEqual(floatSample(in: normalized, at: 3), 0.5, accuracy: 0.0001)
    }

    func testPCMNormalizerHonorsBigEndianSamples() throws {
        let bigEndianMono = Data([0x40, 0x00, 0xC0, 0x00])
        let normalized = try XCTUnwrap(LinearPCMNormalizer.planarFloat32(
            buffers: [bigEndianMono],
            sourceFormat: .int16,
            isInterleaved: false,
            isBigEndian: true,
            channelCount: 1,
            frameCount: 2,
            bytesPerFrame: 2
        ))

        XCTAssertEqual(floatSample(in: normalized, at: 0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(floatSample(in: normalized, at: 1), -0.5, accuracy: 0.0001)
    }

    func testPCMNormalizerAcceptsPaddedInterleavedFrames() throws {
        // Two int16 stereo frames at an 8-byte stride: four bytes of payload and
        // four of padding. An exact-size requirement rejected this outright, which
        // silenced application audio for the rest of the broadcast.
        let padded = Data([
            0x00, 0x00, 0xFF, 0x7F, 0xAA, 0xAA, 0xAA, 0xAA,
            0x00, 0x80, 0x00, 0x40, 0xBB, 0xBB, 0xBB, 0xBB
        ])
        let normalized = try XCTUnwrap(LinearPCMNormalizer.planarFloat32(
            buffers: [padded],
            sourceFormat: .int16,
            isInterleaved: true,
            isBigEndian: false,
            channelCount: 2,
            frameCount: 2,
            bytesPerFrame: 8
        ))

        XCTAssertEqual(floatSample(in: normalized, at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(floatSample(in: normalized, at: 1), -1, accuracy: 0.0001)
        XCTAssertEqual(
            floatSample(in: normalized, at: 2),
            Float(32_767) / 32_768,
            accuracy: 0.0001
        )
        XCTAssertEqual(floatSample(in: normalized, at: 3), 0.5, accuracy: 0.0001)
    }

    func testPCMNormalizerDerivesPlanarStrideRatherThanTrustingIt() throws {
        // A planar buffer whose reported stride covers every channel rather than
        // one sample. Trusting it demanded four times the bytes present and made
        // every frame fail; deriving it from the sample size decodes correctly.
        let planarMono = Data([0x00, 0x40, 0x00, 0xC0])
        let normalized = try XCTUnwrap(LinearPCMNormalizer.planarFloat32(
            buffers: [planarMono],
            sourceFormat: .int16,
            isInterleaved: false,
            isBigEndian: false,
            channelCount: 1,
            frameCount: 2,
            bytesPerFrame: 8
        ))

        XCTAssertEqual(floatSample(in: normalized, at: 0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(floatSample(in: normalized, at: 1), -0.5, accuracy: 0.0001)
    }

    func testPCMNormalizerStillRejectsAnImpossiblySmallInterleavedStride() {
        // Smaller than one packed frame means the layout was misreported; reading
        // it would interleave the channels wrongly, so refuse rather than guess.
        XCTAssertNil(LinearPCMNormalizer.planarFloat32(
            buffers: [Data([0x00, 0x00, 0xFF, 0x7F])],
            sourceFormat: .int16,
            isInterleaved: true,
            isBigEndian: false,
            channelCount: 2,
            frameCount: 2,
            bytesPerFrame: 2
        ))
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

    func testRotationDoesNotInvalidateTheDecoderState() {
        let portrait = VideoConfiguration(
            width: 1080,
            height: 2336,
            orientation: 1,
            sps: Data([1, 2, 3]),
            pps: Data([4, 5]),
            nalUnitHeaderLength: 4,
            nominalFrameRate: 60
        )
        let rotated = VideoConfiguration(
            width: 1080,
            height: 2336,
            orientation: 6,
            sps: Data([1, 2, 3]),
            pps: Data([4, 5]),
            nalUnitHeaderLength: 4,
            nominalFrameRate: 60
        )

        // Equality still differs, which is why comparing whole configurations
        // rebuilt the decoder and blanked the picture on every rotation.
        XCTAssertNotEqual(portrait, rotated)
        XCTAssertTrue(portrait.describesSameDecoderState(as: rotated))
        XCTAssertTrue(rotated.describesSameDecoderState(as: portrait))
    }

    func testDecoderStateChangesInvalidateTheFormatDescription() {
        let base = VideoConfiguration(
            width: 1080,
            height: 2336,
            orientation: 1,
            sps: Data([1, 2, 3]),
            pps: Data([4, 5]),
            nalUnitHeaderLength: 4,
            nominalFrameRate: 60
        )

        func variant(
            width: Int32 = 1080,
            height: Int32 = 2336,
            sps: Data = Data([1, 2, 3]),
            pps: Data = Data([4, 5]),
            nal: Int32? = 4,
            rate: Int32? = 60
        ) -> VideoConfiguration {
            VideoConfiguration(
                width: width,
                height: height,
                orientation: 1,
                sps: sps,
                pps: pps,
                nalUnitHeaderLength: nal,
                nominalFrameRate: rate
            )
        }

        XCTAssertFalse(base.describesSameDecoderState(as: variant(width: 720)))
        XCTAssertFalse(base.describesSameDecoderState(as: variant(height: 1280)))
        XCTAssertFalse(base.describesSameDecoderState(as: variant(sps: Data([9]))))
        XCTAssertFalse(base.describesSameDecoderState(as: variant(pps: Data([9]))))
        XCTAssertFalse(base.describesSameDecoderState(as: variant(nal: 2)))
        XCTAssertFalse(base.describesSameDecoderState(as: variant(rate: 30)))

        // Values that normalise to the same effective metadata must still match,
        // so a legacy payload does not force a needless decoder rebuild.
        XCTAssertTrue(base.describesSameDecoderState(as: variant(nal: nil)))
    }

    func testStreamQualityBoundsNativePhoneResolution() {
        let balanced = StreamQuality.balanced.encodedDimensions(sourceWidth: 1170, sourceHeight: 2532)
        XCTAssertEqual(balanced.width, 720)
        XCTAssertEqual(balanced.height, 1558)

        // 1080 now means 1080 lines across the short edge. The long-edge cap it
        // replaced turned this same source into 498x1080 — a 498-line stream
        // stretched over a landscape viewer, which is what "blurry" looked like.
        let sharp = StreamQuality.sharp.encodedDimensions(sourceWidth: 1170, sourceHeight: 2532)
        XCTAssertEqual(sharp.width, 1080)
        XCTAssertEqual(sharp.height, 2336)

        // The source's short edge is already under Ultra's 1440 bound, so it is
        // passed through natively rather than upscaled.
        let ultra = StreamQuality.ultra.encodedDimensions(sourceWidth: 1170, sourceHeight: 2532)
        XCTAssertEqual(ultra.width, 1170)
        XCTAssertEqual(ultra.height, 2532)

        let saver = StreamQuality.dataSaver.encodedDimensions(sourceWidth: 1170, sourceHeight: 2532)
        XCTAssertEqual(saver.width, 480)
        XCTAssertEqual(saver.height, 1038)
    }

    func testEncodedDimensionsNeverUpscaleBelowTheShortEdgeBound() {
        // Ultra bounds the short edge at 1440; a 1170-wide source must not be
        // stretched up to meet it.
        let ultra = StreamQuality.ultra.encodedDimensions(sourceWidth: 1170, sourceHeight: 2532)
        XCTAssertLessThanOrEqual(ultra.width, 1170)
        XCTAssertLessThanOrEqual(ultra.height, 2532)
    }

    func testRaisedBitRateCeilingsDoNotStarveTheNewResolutions() {
        // A resolution increase is worthless if the ceiling clamps it: the old
        // 8 Mbps cap over 1080x2336 at 60 Hz is 0.05 bits per pixel, which looks
        // worse than the lower resolution it replaced. Assert each quality's
        // pixel-derived request survives its own ceiling unclamped.
        for quality in [StreamQuality.dataSaver, .balanced, .sharp, .ultra] {
            let dimensions = quality.encodedDimensions(sourceWidth: 1170, sourceHeight: 2532)
            let rate = quality.bitRate(width: dimensions.width, height: dimensions.height)
            XCTAssertLessThan(
                rate,
                quality.maximumBitRate,
                "\(quality.rawValue) is clamped by its ceiling and will look blocky"
            )
            let bitsPerPixel = Double(rate)
                / (Double(dimensions.width) * Double(dimensions.height) * Double(quality.framesPerSecond))
            XCTAssertGreaterThan(
                bitsPerPixel,
                0.08,
                "\(quality.rawValue) falls below a usable bits-per-pixel budget"
            )
        }
    }

    func testStreamQualityScalesOlderPhoneResolutionToLowLatencyBound() {
        let dimensions = StreamQuality.balanced.encodedDimensions(sourceWidth: 750, sourceHeight: 1334)
        XCTAssertEqual(dimensions.width, 720)
        XCTAssertEqual(dimensions.height, 1280)
    }

    func testStreamQualityFrameRateTargets() {
        XCTAssertEqual(StreamQuality.balanced.framesPerSecond, 60)
        XCTAssertEqual(StreamQuality.sharp.framesPerSecond, 60)
        XCTAssertEqual(StreamQuality.ultra.framesPerSecond, 60)
        XCTAssertEqual(StreamQuality.dataSaver.framesPerSecond, 60)
        XCTAssertEqual(StreamQuality.balanced.browserFramesPerSecond, 24)
        XCTAssertEqual(StreamQuality.sharp.browserFramesPerSecond, 30)
        XCTAssertEqual(StreamQuality.ultra.browserFramesPerSecond, 30)
        XCTAssertEqual(StreamQuality.dataSaver.browserFramesPerSecond, 30)
        XCTAssertGreaterThan(
            StreamQuality.ultra.bitRate(width: 1_440, height: 1_080),
            StreamQuality.sharp.bitRate(width: 1_080, height: 810)
        )
        // 1440x1080 at 60 Hz and 0.16 bits per pixel is ~14.9 Mbps, which now
        // sits under Ultra's ceiling instead of being clamped to it.
        XCTAssertEqual(StreamQuality.ultra.bitRate(width: 1_440, height: 1_080), 14_929_920)
        XCTAssertEqual(StreamQuality.ultra.maximumBitRate, 32_000_000)
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

    func testNativeAndBrowserDestinationReadinessAreIndependent() {
        let native = SenderConfiguration(
            deliveryMode: .nativeReceiver,
            receiverServiceName: "ScreenShare-12345678",
            pairingCode: "2345-6789-ABCD-EFGH",
            quality: .balanced,
            browserAccessKey: "",
            orientationMode: .landscape,
            rotationDirection: .left,
            framingMode: .fill
        )
        let browser = SenderConfiguration(
            deliveryMode: .browser,
            receiverServiceName: "",
            pairingCode: "",
            quality: .balanced,
            browserAccessKey: "2345-6789-ABCD-EFGH",
            orientationMode: .landscape,
            rotationDirection: .left,
            framingMode: .stretch
        )

        XCTAssertTrue(native.isReady)
        XCTAssertTrue(browser.isReady)
    }

    func testBrowserLinkUsesFixedLocalPortAndNormalizedPrivateKey() throws {
        // Assert the shape, not the exact version. The identity is bumped on
        // purpose whenever the extension binary changes, so pinning the literal
        // only guaranteed this test failed on every deliberate bump. The check
        // that actually matters — that the built .appex Info.plist agrees with
        // this constant — lives in the CI workflow.
        let identity = AppConstants.broadcastBundleIdentifier
        let identityPrefix = "dev.screenshare.sender.broadcast.v"
        XCTAssertTrue(
            identity.hasPrefix(identityPrefix),
            "unexpected broadcast identity: \(identity)"
        )
        XCTAssertNotNil(
            Int(identity.dropFirst(identityPrefix.count)),
            "the broadcast identity must end in a numeric version: \(identity)"
        )
        let url = LocalBrowserLink.url(
            host: "192.168.1.23",
            accessKey: "2345-6789-ABCD-EFGH"
        )

        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host, "192.168.1.23")
        XCTAssertEqual(url?.port, Int(AppConstants.browserViewerPort))
        XCTAssertEqual(AppConstants.browserViewerPort, 49_373)
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(url), resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "k" })?
                .value,
            "23456789ABCDEFGH"
        )
    }

    func testBrowserConfigurationPersistsAcrossStoreInstances() {
        let suiteName = "dev.screenshare.tests.\(UUID().uuidString)"
        guard let writerDefaults = UserDefaults(suiteName: suiteName),
              let readerDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer {
            writerDefaults.removePersistentDomain(forName: suiteName)
        }

        let expected = SenderConfiguration(
            deliveryMode: .browser,
            receiverServiceName: "",
            pairingCode: "",
            quality: .sharp,
            browserAccessKey: "23456789ABCDEFGH",
            orientationMode: .portrait,
            rotationDirection: .right,
            framingMode: .stretch
        )

        SenderConfigurationStore(defaults: writerDefaults).save(expected)
        let actual = SenderConfigurationStore(defaults: readerDefaults).load()

        XCTAssertEqual(actual, expected)
    }

    func testLandscapeModeDefaultsOnForExistingInstallations() {
        let suiteName = "dev.screenshare.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = SenderConfigurationStore(defaults: defaults).load()
        XCTAssertEqual(configuration.orientationMode, .landscape)
        XCTAssertEqual(configuration.rotationDirection, .left)
        XCTAssertEqual(configuration.framingMode, .fill)
    }

    func testVersion33LandscapeSettingMigratesToOrientationMode() {
        let suiteName = "dev.screenshare.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "alwaysLandscape")
        XCTAssertEqual(
            SenderConfigurationStore(defaults: defaults).load().orientationMode,
            .automatic
        )

        defaults.set(true, forKey: "alwaysLandscape")
        XCTAssertEqual(
            SenderConfigurationStore(defaults: defaults).load().orientationMode,
            .landscape
        )
    }

    func testBrowserWebAppManifestKeepsPrivateStartURLAndNeutralBranding() throws {
        let manifestData = BrowserWebApp.manifest(accessKey: "2345-6789-ABCD-EFGH")
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )

        XCTAssertEqual(manifest["name"] as? String, "Screen Share")
        XCTAssertEqual(manifest["short_name"] as? String, "Screen Share")
        XCTAssertEqual(manifest["display"] as? String, "fullscreen")
        XCTAssertEqual(
            manifest["display_override"] as? [String],
            ["fullscreen", "standalone"]
        )
        XCTAssertEqual(manifest["orientation"] as? String, "any")
        XCTAssertEqual(manifest["start_url"] as? String, "/?k=23456789ABCDEFGH")
        let icons = try XCTUnwrap(manifest["icons"] as? [[String: Any]])
        XCTAssertEqual(icons.first?["src"] as? String, "/icon.png")
        XCTAssertTrue(BrowserWebApp.iconPNG.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func testBrowserConnectionBudgetAllowsPageAssetsVideoAndAudio() {
        XCTAssertGreaterThanOrEqual(AppConstants.maximumBrowserConnections, 16)
    }

    func testBrowserHTTPHeadersEndWithCompleteCRLFDelimiter() {
        let data = BrowserHTTPWire.headerBlock([
            "HTTP/1.1 200 OK",
            "Content-Type: text/plain",
            "Content-Length: 2"
        ])

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n"
        )
        XCTAssertEqual(Data(data.suffix(4)), Data([13, 10, 13, 10]))
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
                encodedWidth: 664,
                encodedHeight: 1_440,
                videoOrientation: 8
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

    func testRawReplayKitQuarterTurnsMatchReceiverDisplayCoordinates() {
        XCTAssertEqual(
            VideoRendererView.rotationAngle(for: 6),
            .pi / 2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            VideoRendererView.rotationAngle(for: 8),
            -.pi / 2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            VideoRendererView.rotationAngle(for: 3),
            .pi,
            accuracy: 0.0001
        )
    }

    func testReplayKitOrientationKeepsValidAttachmentMetadata() {
        XCTAssertEqual(
            ReplayKitOrientationResolver.resolve(
                attachedValue: 6,
                pixelWidth: 1_440,
                pixelHeight: 664
            ),
            6
        )
        XCTAssertEqual(
            ReplayKitOrientationResolver.resolve(
                attachedValue: 8,
                pixelWidth: 1_440,
                pixelHeight: 664
            ),
            8
        )
    }

    func testReplayKitOrientationRepairsStaleWideUpAndDownMetadata() {
        XCTAssertEqual(
            ReplayKitOrientationResolver.resolve(
                attachedValue: 1,
                pixelWidth: 1_440,
                pixelHeight: 664
            ),
            3
        )
        XCTAssertEqual(
            ReplayKitOrientationResolver.resolve(
                attachedValue: 3,
                pixelWidth: 1_440,
                pixelHeight: 664
            ),
            1
        )
        XCTAssertEqual(
            ReplayKitOrientationResolver.resolve(
                attachedValue: 1,
                pixelWidth: 664,
                pixelHeight: 1_440
            ),
            1
        )
    }

    func testReplayKitOrientationRepairsUntaggedLandscapeBuffer() {
        XCTAssertEqual(
            ReplayKitOrientationResolver.resolve(
                attachedValue: nil,
                pixelWidth: 1_440,
                pixelHeight: 664
            ),
            3
        )
        XCTAssertEqual(
            ReplayKitOrientationResolver.resolve(
                attachedValue: nil,
                pixelWidth: 664,
                pixelHeight: 1_440
            ),
            1
        )
    }

    func testReplayKitOrientationRepairsPortraitShapedLandscapeBuffers() {
        XCTAssertEqual(
            ReplayKitOrientationResolver.resolve(
                attachedValue: 6,
                pixelWidth: 664,
                pixelHeight: 1_440
            ),
            8
        )
        XCTAssertEqual(
            ReplayKitOrientationResolver.resolve(
                attachedValue: 8,
                pixelWidth: 664,
                pixelHeight: 1_440
            ),
            6
        )
        XCTAssertEqual(
            ReplayKitOrientationResolver.resolve(
                attachedValue: 5,
                pixelWidth: 664,
                pixelHeight: 1_440
            ),
            7
        )
        XCTAssertEqual(
            ReplayKitOrientationResolver.resolve(
                attachedValue: 7,
                pixelWidth: 664,
                pixelHeight: 1_440
            ),
            5
        )
    }

    func testForcedOrientationRotatesWithoutChangingMatchingGeometry() {
        XCTAssertEqual(
            StreamOrientationPolicy.resolve(
                orientation: 1,
                pixelWidth: 664,
                pixelHeight: 1_440,
                mode: .landscape,
                direction: .left
            ),
            8
        )
        XCTAssertEqual(
            StreamOrientationPolicy.resolve(
                orientation: 3,
                pixelWidth: 664,
                pixelHeight: 1_440,
                mode: .landscape,
                direction: .left
            ),
            6
        )
        XCTAssertEqual(
            StreamOrientationPolicy.resolve(
                orientation: 8,
                pixelWidth: 664,
                pixelHeight: 1_440,
                mode: .landscape,
                direction: .left
            ),
            8
        )
        XCTAssertEqual(
            StreamOrientationPolicy.resolve(
                orientation: 1,
                pixelWidth: 664,
                pixelHeight: 1_440,
                mode: .automatic,
                direction: .left
            ),
            1
        )
        XCTAssertEqual(
            StreamOrientationPolicy.resolve(
                orientation: 8,
                pixelWidth: 664,
                pixelHeight: 1_440,
                mode: .portrait,
                direction: .left
            ),
            3
        )
        XCTAssertEqual(
            StreamOrientationPolicy.resolve(
                orientation: 8,
                pixelWidth: 664,
                pixelHeight: 1_440,
                mode: .portrait,
                direction: .right
            ),
            1
        )
    }

    func testForcedOrientationAlwaysProducesRequestedAspect() {
        func displaySize(
            orientation: UInt32,
            pixelWidth: Int,
            pixelHeight: Int
        ) -> (width: Int, height: Int) {
            (5...8).contains(orientation)
                ? (pixelHeight, pixelWidth)
                : (pixelWidth, pixelHeight)
        }

        for (pixelWidth, pixelHeight) in [(664, 1_440), (1_440, 664)] {
            for orientation in UInt32(1)...UInt32(8) {
                let landscape = StreamOrientationPolicy.resolve(
                    orientation: orientation,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    mode: .landscape,
                    direction: .left
                )
                let landscapeSize = displaySize(
                    orientation: landscape,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight
                )
                XCTAssertGreaterThan(landscapeSize.width, landscapeSize.height)

                let portrait = StreamOrientationPolicy.resolve(
                    orientation: orientation,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    mode: .portrait,
                    direction: .right
                )
                let portraitSize = displaySize(
                    orientation: portrait,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight
                )
                XCTAssertLessThan(portraitSize.width, portraitSize.height)
            }
        }
    }

    private func floatSample(in data: Data, at index: Int) -> Float {
        let raw = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
        }
        return Float(bitPattern: UInt32(littleEndian: raw))
    }
}
