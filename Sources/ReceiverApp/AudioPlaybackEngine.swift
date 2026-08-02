import AVFoundation
import Foundation

final class AudioPlaybackEngine {
    private struct FormatKey: Equatable {
        let channelCount: UInt8
        let sampleRate: UInt32
    }

    private let queue = DispatchQueue(label: "dev.screenshare.receiver.audio", qos: .userInteractive)
    private let stateLock = NSLock()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var activeFormat: FormatKey?
    private var scheduledBufferCount = 0
    private var generation: UInt64 = 0
    private var backgroundPlaybackActive = false

    init() {
        engine.attach(player)
    }

    var isBackgroundPlaybackActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return backgroundPlaybackActive
    }

    func enqueue(_ frame: AudioPCMFrame) {
        queue.async { [weak self] in
            self?.enqueueInternal(frame)
        }
    }

    func reset() {
        queue.async { [weak self] in
            self?.resetInternal(deactivateSession: true)
        }
    }

    private func enqueueInternal(_ frame: AudioPCMFrame) {
        let key = FormatKey(
            channelCount: frame.channelCount,
            sampleRate: frame.sampleRate
        )
        guard configureIfNeeded(for: key),
              let format = makeFormat(for: key),
              let buffer = makeBuffer(from: frame, format: format) else {
            return
        }

        if scheduledBufferCount >= AppConstants.maximumPendingAudioFrames {
            generation &+= 1
            scheduledBufferCount = 0
            player.stop()
            player.play()
        }

        let scheduledGeneration = generation
        scheduledBufferCount += 1
        player.scheduleBuffer(buffer) { [weak self] in
            self?.queue.async {
                guard let self, self.generation == scheduledGeneration else { return }
                self.scheduledBufferCount = max(0, self.scheduledBufferCount - 1)
            }
        }
    }

    private func configureIfNeeded(for key: FormatKey) -> Bool {
        if activeFormat == key, engine.isRunning {
            if !player.isPlaying {
                player.play()
            }
            setBackgroundPlaybackActive(true)
            return true
        }

        resetInternal(deactivateSession: false)
        guard let format = makeFormat(for: key) else { return false }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            player.play()
            activeFormat = key
            setBackgroundPlaybackActive(true)
            return true
        } catch {
            resetInternal(deactivateSession: true)
            return false
        }
    }

    private func makeFormat(for key: FormatKey) -> AVAudioFormat? {
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(key.sampleRate),
            channels: AVAudioChannelCount(key.channelCount),
            interleaved: false
        )
    }

    private func makeBuffer(from frame: AudioPCMFrame, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frame.frameCount)
        ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frame.frameCount)

        guard let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(frame.channelCount)
        let frameCount = Int(frame.frameCount)
        return frame.samples.withUnsafeBytes { sourceBytes in
            guard !sourceBytes.isEmpty else { return nil }
            for channel in 0..<channelCount {
                let destination = channels[channel]
                for frameIndex in 0..<frameCount {
                    let sampleIndex = frame.isInterleaved
                        ? frameIndex * channelCount + channel
                        : channel * frameCount + frameIndex
                    let byteOffset = sampleIndex * frame.format.bytesPerSample
                    switch frame.format {
                    case .float32:
                        let raw = sourceBytes.loadUnaligned(
                            fromByteOffset: byteOffset,
                            as: UInt32.self
                        )
                        destination[frameIndex] = Float(
                            bitPattern: UInt32(littleEndian: raw)
                        )
                    case .int16:
                        let raw = sourceBytes.loadUnaligned(
                            fromByteOffset: byteOffset,
                            as: UInt16.self
                        )
                        destination[frameIndex] = Float(Int16(
                            bitPattern: UInt16(littleEndian: raw)
                        )) / 32_768
                    case .int32:
                        let raw = sourceBytes.loadUnaligned(
                            fromByteOffset: byteOffset,
                            as: UInt32.self
                        )
                        destination[frameIndex] = Float(Int32(
                            bitPattern: UInt32(littleEndian: raw)
                        )) / 2_147_483_648
                    }
                }
            }
            return buffer
        }
    }

    private func resetInternal(deactivateSession: Bool) {
        generation &+= 1
        scheduledBufferCount = 0
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.reset()
        activeFormat = nil
        setBackgroundPlaybackActive(false)

        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func setBackgroundPlaybackActive(_ value: Bool) {
        stateLock.lock()
        backgroundPlaybackActive = value
        stateLock.unlock()
    }

    deinit {
        player.stop()
        engine.stop()
    }
}
