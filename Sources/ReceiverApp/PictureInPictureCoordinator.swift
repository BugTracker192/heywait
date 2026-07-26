import AVFoundation
import AVKit
import Combine
import CoreMedia
import Foundation
import UIKit

final class PictureInPictureCoordinator: NSObject, ObservableObject {
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var activeObservation: NSKeyValueObservation?
    private var foregroundObserver: NSObjectProtocol?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        super.init()
        configureAudioSession()
        configureController(displayLayer: displayLayer)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if self?.controller?.isPictureInPictureActive == true {
                self?.controller?.stopPictureInPicture()
            }
        }
    }

    func updateDisplayLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        controller?.stopPictureInPicture()
        possibleObservation?.invalidate()
        possibleObservation = nil
        activeObservation?.invalidate()
        activeObservation = nil
        controller = nil
        isPossible = false
        isActive = false
        configureController(displayLayer: displayLayer)
    }

    func toggle() {
        guard let controller, controller.isPictureInPicturePossible else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    func invalidatePlaybackState() {
        controller?.invalidatePlaybackState()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // PiP can remain unavailable if another system audio session has priority.
        }
    }

    private func configureController(displayLayer: AVSampleBufferDisplayLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        self.controller = controller

        possibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            DispatchQueue.main.async {
                self?.isPossible = controller.isPictureInPicturePossible
            }
        }
        activeObservation = controller.observe(
            \.isPictureInPictureActive,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            DispatchQueue.main.async {
                self?.isActive = controller.isPictureInPictureActive
            }
        }
    }

    deinit {
        possibleObservation?.invalidate()
        activeObservation?.invalidate()
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }
}

extension PictureInPictureCoordinator: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }
}

extension PictureInPictureCoordinator: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

