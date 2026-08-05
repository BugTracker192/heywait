import Foundation

enum AudioPCMSampleFormat: UInt8, Equatable {
    case float32 = 1
    case int16 = 2
    case int32 = 3

    var bytesPerSample: Int {
        switch self {
        case .float32, .int32:
            return 4
        case .int16:
            return 2
        }
    }
}

struct AudioPCMFrame: Equatable {
    private static let version: UInt8 = 1
    private static let headerByteCount = 24

    // Flag bits in header byte 2. Bit 0 has always carried interleaving; bit 1
    // is new and marks a microphone frame. Older decoders mask only bit 0, so a
    // mic frame still decodes as ordinary audio for them rather than failing.
    private static let interleavedFlag: UInt8 = 1 << 0
    private static let microphoneFlag: UInt8 = 1 << 1

    let format: AudioPCMSampleFormat
    let isInterleaved: Bool
    let channelCount: UInt8
    let sampleRate: UInt32
    let frameCount: UInt32
    let timestampMicroseconds: UInt64
    let samples: Data
    // Microphone and application audio arrive from ReplayKit as independent
    // streams with their own rates and packet cadence. They are tagged and sent
    // separately so the receiver can schedule each on its own clock and let its
    // mixer combine them; resampling and mixing inside the broadcast extension
    // would cost memory the extension does not have.
    let isMicrophone: Bool

    var encoded: Data {
        var flags: UInt8 = 0
        if isInterleaved { flags |= Self.interleavedFlag }
        if isMicrophone { flags |= Self.microphoneFlag }

        var data = Data()
        data.append(Self.version)
        data.append(format.rawValue)
        data.append(flags)
        data.append(channelCount)
        data.appendAudioBigEndian(sampleRate)
        data.appendAudioBigEndian(frameCount)
        data.appendAudioBigEndian(timestampMicroseconds)
        data.appendAudioBigEndian(UInt32(samples.count))
        data.append(samples)
        return data
    }

    init(
        format: AudioPCMSampleFormat,
        isInterleaved: Bool,
        channelCount: UInt8,
        sampleRate: UInt32,
        frameCount: UInt32,
        timestampMicroseconds: UInt64,
        samples: Data,
        isMicrophone: Bool = false
    ) throws {
        guard (1...2).contains(channelCount),
              (8_000...192_000).contains(sampleRate),
              frameCount > 0 else {
            throw AudioPCMFrameError.invalidMetadata
        }
        let expectedBytes = Int(frameCount)
            * Int(channelCount)
            * format.bytesPerSample
        guard samples.count == expectedBytes,
              samples.count <= AppConstants.maximumAudioFrameBytes else {
            throw AudioPCMFrameError.invalidPayloadLength
        }
        self.format = format
        self.isInterleaved = isInterleaved
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.timestampMicroseconds = timestampMicroseconds
        self.samples = samples
        self.isMicrophone = isMicrophone
    }

    init(encoded data: Data) throws {
        guard data.count >= Self.headerByteCount,
              data.audioByte(at: 0) == Self.version,
              let format = AudioPCMSampleFormat(rawValue: data.audioByte(at: 1)) else {
            throw AudioPCMFrameError.invalidHeader
        }
        let flags = data.audioByte(at: 2)
        let channelCount = data.audioByte(at: 3)
        let sampleRate = data.audioUInt32(at: 4)
        let frameCount = data.audioUInt32(at: 8)
        let timestamp = data.audioUInt64(at: 12)
        let payloadLength = Int(data.audioUInt32(at: 20))
        guard payloadLength <= AppConstants.maximumAudioFrameBytes,
              data.count == Self.headerByteCount + payloadLength else {
            throw AudioPCMFrameError.invalidPayloadLength
        }
        try self.init(
            format: format,
            isInterleaved: flags & Self.interleavedFlag == Self.interleavedFlag,
            channelCount: channelCount,
            sampleRate: sampleRate,
            frameCount: frameCount,
            timestampMicroseconds: timestamp,
            samples: Data(data.dropFirst(Self.headerByteCount)),
            isMicrophone: flags & Self.microphoneFlag == Self.microphoneFlag
        )
    }
}

enum AudioPCMFrameError: Error {
    case invalidHeader
    case invalidMetadata
    case invalidPayloadLength
}

private extension Data {
    mutating func appendAudioBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func audioByte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func audioUInt32(at offset: Int) -> UInt32 {
        (UInt32(audioByte(at: offset)) << 24)
            | (UInt32(audioByte(at: offset + 1)) << 16)
            | (UInt32(audioByte(at: offset + 2)) << 8)
            | UInt32(audioByte(at: offset + 3))
    }

    func audioUInt64(at offset: Int) -> UInt64 {
        (UInt64(audioUInt32(at: offset)) << 32)
            | UInt64(audioUInt32(at: offset + 4))
    }
}
