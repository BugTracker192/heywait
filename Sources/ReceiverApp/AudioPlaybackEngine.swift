import AVFoundation
import Foundation

final class AudioPlaybackEngine {
    private struct FormatKey: Equatable {
        let channelCount: UInt8
        let sampleRate: UInt32
    }

    // App audio and microphone audio are independent ReplayKit streams and
    // routinely differ in sample rate and channel count. One shared player node
    // would reconfigure — and therefore tear down the whole engine — on every
    // alternating frame, so each source gets its own node and its own format.
    private final class Track {
        let player = AVAudioPlayerNode()
        var activeFormat: FormatKey?
        var scheduledBufferCount = 0
        var generation: UInt64 = 0
    }

    private let queue = DispatchQueue(label: "dev.screenshare.receiver.audio", qos: .userInteractive)
    private let stateLock = NSLock()
    private let engine = AVAudioEngine()
    private let appTrack = Track()
    private let microphoneTrack = Track()
    private var backgroundPlaybackActive = false

    init() {
        engine.attach(appTrack.player)
        engine.attach(microphoneTrack.player)
    }

    private var tracks: [Track] { [appTrack, microphoneTrack] }

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
        let track = frame.isMicrophone ? microphoneTrack : appTrack
        let key = FormatKey(
            channelCount: frame.channelCount,
            sampleRate: frame.sampleRate
        )
        guard let format = makeFormat(for: key),
              configureIfNeeded(track: track, key: key, format: format),
              let buffer = makeBuffer(from: frame, format: format) else {
            return
        }

        if track.scheduledBufferCount >= AppConstants.maximumPendingAudioFrames {
            track.generation &+= 1
            track.scheduledBufferCount = 0
            track.player.stop()
            track.player.play()
        }

        let scheduledGeneration = track.generation
        track.scheduledBufferCount += 1
        track.player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard track.generation == scheduledGeneration else { return }
                track.scheduledBufferCount = max(0, track.scheduledBufferCount - 1)
            }
        }
    }

    private func configureIfNeeded(
        track: Track,
        key: FormatKey,
        format: AVAudioFormat
    ) -> Bool {
        if track.activeFormat == key, engine.isRunning {
            if !track.player.isPlaying {
                track.player.play()
            }
            setBackgroundPlaybackActive(true)
            return true
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)

            // Reconnecting requires stopping the engine, which discards buffers
            // already scheduled on the other track too. Invalidate both counters
            // so neither is left believing it still has audio queued.
            if engine.isRunning {
                engine.stop()
            }
            for other in tracks {
                other.player.stop()
                other.generation &+= 1
                other.scheduledBufferCount = 0
            }

            engine.disconnectNodeOutput(track.player)
            engine.connect(track.player, to: engine.mainMixerNode, format: format)
            track.activeFormat = key

            engine.prepare()
            try engine.start()

            // Only this track's format changed; every configured track resumes.
            for other in tracks where other.activeFormat != nil {
                other.player.play()
            }
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
        for track in tracks {
            track.generation &+= 1
            track.scheduledBufferCount = 0
            track.player.stop()
        }
        engine.stop()
        for track in tracks {
            engine.disconnectNodeOutput(track.player)
            track.activeFormat = nil
        }
        engine.reset()
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
        for track in tracks {
            track.player.stop()
        }
        engine.stop()
    }
}
