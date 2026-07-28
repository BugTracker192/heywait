import Foundation

enum AppConstants {
    static let protocolVersion: UInt8 = 2
    static let serviceType = "_screenshare._tcp"
    static let serviceDomain = "local."
    static let appGroup = "group.dev.screenshare.sender"
    // v2 deliberately uses a new extension identity so TrollStore/iOS cannot
    // keep launching a cached upload extension from an older installation.
    static let broadcastBundleIdentifier = "dev.screenshare.sender.broadcast.v2"
    static let maximumPacketBytes = 8 * 1024 * 1024
    static let maximumAudioFrameBytes = 512 * 1024
    static let maximumPendingAudioFrames = 10
    static let preferredFramesPerSecond = 60
    static let maximumOutstandingVideoFrames = 16
    static let maximumInFlightNetworkSends = 8
    static let allowsAutomaticPictureInPicture = false
    static let receiverBackgroundGraceSeconds: TimeInterval = 60
    static let browserViewerPort: UInt16 = 49_373
    static let maximumBrowserClients = 4
}

