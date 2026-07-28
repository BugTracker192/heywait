import AudioToolbox
import CoreMedia
import Foundation

enum CapturedAudioPCMFrame {
    static func make(from sampleBuffer: CMSampleBuffer) -> AudioPCMFrame? {
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
        let bytesPerFrame = Int(description.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
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
                    let requiredBytes = frameCount * bytesPerFrame
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
                    bytesPerFrame: bytesPerFrame
                ) else { return nil }

                return try AudioPCMFrame(
                    format: .float32,
                    isInterleaved: false,
                    channelCount: UInt8(channels),
                    sampleRate: UInt32(description.mSampleRate.rounded()),
                    frameCount: UInt32(frameCount),
                    timestampMicroseconds: timestampMicroseconds,
                    samples: samples
                )
            }
        } catch {
            return nil
        }
    }
}
