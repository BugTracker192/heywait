import AVFoundation
import AVKit
import Combine
import CoreMedia
import Foundation
import UIKit

final class PictureInPictureCoordinator: NSObject, ObservableObject {
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false

    private var displayLayer: AVSampleBufferDisplayLayer
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var activeObservation: NSKeyValueObservation?
    private var foregroundObserver: NSObjectProtocol?
    private var manualStartPending = false
    private(set) var isUserInitiated = false

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init()
        isPossible = AVPictureInPictureController.isPictureInPictureSupported()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopForForeground()
        }
    }

    func updateDisplayLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        isUserInitiated = false
        manualStartPending = false
        controller?.stopPictureInPicture()
        tearDownController()
        self.displayLayer = displayLayer
        isPossible = AVPictureInPictureController.isPictureInPictureSupported()
    }

    func toggle() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if let controller, controller.isPictureInPictureActive {
            isUserInitiated = false
            manualStartPending = false
            controller.stopPictureInPicture()
        } else {
            isUserInitiated = true
            manualStartPending = true
            configureAudioSession()
            configureControllerIfNeeded()
            startPendingPictureInPictureIfPossible()
        }
    }

    func suppressAutomaticPictureInPicture() {
        guard !isUserInitiated else { return }
        manualStartPending = false
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        } else {
            tearDownController()
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

    private func configureControllerIfNeeded() {
        guard controller == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline =
            AppConstants.allowsAutomaticPictureInPicture
        controller.requiresLinearPlayback = true
        self.controller = controller

        possibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPossible = controller.isPictureInPicturePossible
                self.startPendingPictureInPictureIfPossible()
            }
        }
        activeObservation = controller.observe(
            \.isPictureInPictureActive,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isActive = controller.isPictureInPictureActive
                if controller.isPictureInPictureActive, !self.isUserInitiated {
                    controller.stopPictureInPicture()
                }
            }
        }
    }

    private func startPendingPictureInPictureIfPossible() {
        guard manualStartPending,
              isUserInitiated,
              let controller,
              controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive else {
            return
        }
        manualStartPending = false
        controller.startPictureInPicture()
    }

    private func stopForForeground() {
        isUserInitiated = false
        manualStartPending = false
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        } else {
            tearDownController()
        }
    }

    private func tearDownController() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        activeObservation?.invalidate()
        activeObservation = nil
        controller = nil
        isActive = false
        isPossible = AVPictureInPictureController.isPictureInPictureSupported()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
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
    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isUserInitiated = false
        manualStartPending = false
        tearDownController()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isUserInitiated = false
        manualStartPending = false
        tearDownController()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

