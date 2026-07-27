import Foundation

enum AppConstants {
    static let protocolVersion: UInt8 = 1
    static let serviceType = "_screenshare._tcp"
    static let serviceDomain = "local."
    static let appGroup = "group.dev.screenshare.sender"
    static let broadcastBundleIdentifier = "dev.screenshare.sender.broadcast"
    static let maximumPacketBytes = 8 * 1024 * 1024
    static let preferredFramesPerSecond = 60
    static let maximumOutstandingVideoFrames = 2
}

