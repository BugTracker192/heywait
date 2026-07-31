import Foundation

enum ReplayKitOrientationResolver {
    static func resolve(
        attachedValue: UInt32?,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> UInt32 {
        if let attachedValue, (1...8).contains(attachedValue) {
            return attachedValue
        }

        // RPVideoSampleOrientationKey is deprecated and can be absent from
        // Broadcast Upload samples. On the affected iOS 16 ReplayKit path,
        // portrait buffers arrive upright while an untagged wide buffer is
        // stored with its display origin inverted. Normalize that fallback at
        // the sender so native and browser receivers get one stable value.
        return pixelWidth > pixelHeight ? 3 : 1
    }
}
