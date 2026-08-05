import Foundation

enum AppConstants {
    static let protocolVersion: UInt8 = 2
    static let serviceType = "_screenshare._tcp"
    static let serviceDomain = "local."
    static let appGroup = "group.dev.screenshare.sender"
    // v19 deliberately uses a new extension identity so TrollStore/iOS cannot
    // keep launching a cached upload extension from an older installation.
    static let broadcastBundleIdentifier = "dev.screenshare.sender.broadcast.v19"
    static let orientationDiagnosticKey = "lastReplayKitOrientationDiagnostic"
    // Application audio can stop mid-broadcast when another app changes the
    // system audio session — joining a call, for example. The capture path
    // rejects an unexpected format silently, so record the last format seen and
    // whether it was accepted; otherwise the only symptom is missing audio with
    // nothing to diagnose it from.
    static let audioDiagnosticKey = "lastCapturedAudioDiagnostic"
    static let maximumPacketBytes = 8 * 1024 * 1024
    static let maximumAudioFrameBytes = 512 * 1024
    static let maximumPendingAudioFrames = 10
    static let preferredFramesPerSecond = 60
    static let maximumOutstandingVideoFrames = 16
    static let maximumInFlightNetworkSends = 8
    static let allowsAutomaticPictureInPicture = false
    static let browserViewerPort: UInt16 = 49_373
    // A single browser viewer can briefly hold the HTML, icon, manifest,
    // video, and audio requests at the same time. Safari also keeps the
    // scanned tab alive while launching an installed Home Screen web app.
    // Bound total HTTP connections without mistaking those subrequests for
    // separate viewers.
    static let maximumBrowserConnections = 24
}

