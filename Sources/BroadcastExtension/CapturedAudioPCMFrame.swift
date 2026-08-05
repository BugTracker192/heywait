import AudioToolbox
import CoreMedia
import Foundation

enum CapturedAudioPCMFrame {
    // Compact description of what ReplayKit actually handed over, for the sender
    // UI's diagnostic line. Only used when the summary changes, so it never runs
    // per frame at audio rate.
    static func formatSummary(of sampleBuffer: CMSampleBuffer) -> String {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?
                .pointee else {
            return "no format description"
        }
        let layout = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            ? "interleaved"
            : "planar"
        let kind: String
        if description.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            kind = "float"
        } else if description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            kind = "int"
        } else {
            kind = "other"
        }
        return "\(Int(description.mSampleRate))Hz"
            + " \(description.mChannelsPerFrame)ch"
            + " \(kind)\(description.mBitsPerChannel)"
            + " \(layout)"
            + " stride \(description.mBytesPerFrame)"
    }

    static func make(from sampleBuffer: CMSampleBuffer, isMicrophone: Bool = false) -> AudioPCMFrame? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?
                .pointee,
              description.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }

        let channels = Int(description.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard (1...2).contains(channels),
              frameCount > 0,
              description.mSampleRate.isFinite,
              description.mSampleRate >= 8_000,
              description.mSampleRate <= 192_000 else {
            return nil
        }

        let flags = description.mFormatFlags
        let sampleFormat: AudioPCMSampleFormat
        if flags & kAudioFormatFlagIsFloat != 0,
           description.mBitsPerChannel == 32 {
            sampleFormat = .float32
        } else if flags & kAudioFormatFlagIsSignedInteger != 0,
                  description.mBitsPerChannel == 16 {
            sampleFormat = .int16
        } else if flags & kAudioFormatFlagIsSignedInteger != 0,
                  description.mBitsPerChannel == 32 {
            sampleFormat = .int32
        } else {
            return nil
        }

        let isInterleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
        let expectedBufferCount = isInterleaved ? 1 : channels
        let reportedBytesPerFrame = Int(description.mBytesPerFrame)
        guard reportedBytesPerFrame > 0 else { return nil }

        // Stride between consecutive frames inside one source buffer.
        //
        // Core Audio reports mBytesPerFrame per buffer, so for non-interleaved
        // audio it should already equal a single sample. Deriving it rather than
        // trusting it matters: a larger reported value made the bounds check below
        // demand more bytes than the buffer actually holds, so every frame was
        // rejected and application audio went silent for the remainder of the
        // broadcast — with no diagnostic and no recovery, which is why restarting
        // the broadcast was the only cure. Interleaved frames may legitimately
        // carry padding, so there the reported stride wins when it is big enough.
        let frameStride = isInterleaved
            ? max(reportedBytesPerFrame, sampleFormat.bytesPerSample * channels)
            : sampleFormat.bytesPerSample
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampMicroseconds: UInt64
        if timestamp.isValid, timestamp.seconds.isFinite, timestamp.seconds > 0 {
            timestampMicroseconds = UInt64(timestamp.seconds * 1_000_000)
        } else {
            timestampMicroseconds = 0
        }

        do {
            return try sampleBuffer.withAudioBufferList(
                flags: .audioBufferListAssure16ByteAlignment
            ) { buffers, _ in
                guard buffers.count == expectedBufferCount else { return nil }
                var sourceBuffers: [Data] = []
                sourceBuffers.reserveCapacity(buffers.count)
                for buffer in buffers {
                    let requiredBytes = frameCount * frameStride
                    guard let source = buffer.mData,
                          Int(buffer.mDataByteSize) >= requiredBytes else {
                        return nil
                    }
                    sourceBuffers.append(Data(bytes: source, count: requiredBytes))
                }
                guard let samples = LinearPCMNormalizer.planarFloat32(
                    buffers: sourceBuffers,
                    sourceFormat: sampleFormat,
                    isInterleaved: isInterleaved,
                    isBigEndian: flags & kAudioFormatFlagIsBigEndian != 0,
                    channelCount: channels,
                    frameCount: frameCount,
                    bytesPerFrame: frameStride
                ) else { return nil }

                return try AudioPCMFrame(
                    format: .float32,
                    isInterleaved: false,
                    channelCount: UInt8(channels),
                    sampleRate: UInt32(description.mSampleRate.rounded()),
                    frameCount: UInt32(frameCount),
                    timestampMicroseconds: timestampMicroseconds,
                    samples: samples,
                    isMicrophone: isMicrophone
                )
            }
        } catch {
            return nil
        }
    }
}
