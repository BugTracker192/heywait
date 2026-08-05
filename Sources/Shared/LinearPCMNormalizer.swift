import Foundation

enum LinearPCMNormalizer {
    static func planarFloat32(
        buffers: [Data],
        sourceFormat: AudioPCMSampleFormat,
        isInterleaved: Bool,
        isBigEndian: Bool,
        channelCount: Int,
        frameCount: Int,
        bytesPerFrame: Int
    ) -> Data? {
        guard (1...2).contains(channelCount),
              frameCount > 0,
              bytesPerFrame > 0 else {
            return nil
        }

        let bytesPerSample = sourceFormat.bytesPerSample
        guard buffers.count == (isInterleaved ? 1 : channelCount) else {
            return nil
        }

        // Stride between consecutive frames within one source buffer.
        //
        // This used to require bytesPerFrame equal the tightly packed size and
        // returned nil otherwise, so any padded or differently reported format
        // silently dropped every frame — permanently, since nothing retries. Now
        // a padded interleaved stride is accepted, while a non-interleaved stride
        // is derived from the sample size so a wrong value cannot make the reader
        // skip samples and garble the audio.
        let frameStride: Int
        if isInterleaved {
            guard bytesPerFrame >= bytesPerSample * channelCount else { return nil }
            frameStride = bytesPerFrame
        } else {
            frameStride = bytesPerSample
        }

        let requiredBufferBytes = frameCount * frameStride
        guard buffers.allSatisfy({ $0.count >= requiredBufferBytes }) else {
            return nil
        }

        var output = Data()
        output.reserveCapacity(frameCount * channelCount * MemoryLayout<Float>.size)
        for channel in 0..<channelCount {
            let source = buffers[isInterleaved ? 0 : channel]
            for frame in 0..<frameCount {
                let sampleOffset = frame * frameStride
                    + (isInterleaved ? channel * bytesPerSample : 0)
                let sample = readSample(
                    source,
                    offset: sampleOffset,
                    format: sourceFormat,
                    isBigEndian: isBigEndian
                )
                let finiteSample = sample.isFinite ? min(1, max(-1, sample)) : 0
                var bits = finiteSample.bitPattern.littleEndian
                Swift.withUnsafeBytes(of: &bits) { output.append(contentsOf: $0) }
            }
        }
        return output
    }

    private static func readSample(
        _ data: Data,
        offset: Int,
        format: AudioPCMSampleFormat,
        isBigEndian: Bool
    ) -> Float {
        switch format {
        case .float32:
            let raw = readUInt32(data, offset: offset, isBigEndian: isBigEndian)
            return Float(bitPattern: raw)
        case .int16:
            let raw = readUInt16(data, offset: offset, isBigEndian: isBigEndian)
            return Float(Int16(bitPattern: raw)) / 32_768
        case .int32:
            let raw = readUInt32(data, offset: offset, isBigEndian: isBigEndian)
            return Float(Int32(bitPattern: raw)) / 2_147_483_648
        }
    }

    private static func readUInt16(_ data: Data, offset: Int, isBigEndian: Bool) -> UInt16 {
        let first = UInt16(data[data.index(data.startIndex, offsetBy: offset)])
        let second = UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)])
        return isBigEndian
            ? (first << 8) | second
            : first | (second << 8)
    }

    private static func readUInt32(_ data: Data, offset: Int, isBigEndian: Bool) -> UInt32 {
        let bytes = (0..<4).map {
            UInt32(data[data.index(data.startIndex, offsetBy: offset + $0)])
        }
        if isBigEndian {
            return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
        }
        return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)
    }
}
