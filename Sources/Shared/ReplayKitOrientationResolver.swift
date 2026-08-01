import Foundation

enum ReplayKitOrientationResolver {
    static func resolve(
        attachedValue: UInt32?,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> UInt32 {
        if let attachedValue, (1...8).contains(attachedValue) {
            // iOS 16 can keep reporting a valid-looking `.up`/`.down`
            // attachment after ReplayKit changes to a physically wide
            // buffer. On affected devices the pixels in that wide buffer are
            // stored on the opposite landscape side, so trusting the stale
            // value leaves both the native and browser viewers upside down.
            // Repair only the wide, non-quarter-turn case; genuine EXIF 5...8
            // metadata still describes a portrait-shaped buffer correctly.
            guard pixelWidth > pixelHeight else { return attachedValue }
            switch attachedValue {
            case 1: return 3
            case 2: return 4
            case 3: return 1
            case 4: return 2
            default: return attachedValue
            }
        }

        // RPVideoSampleOrientationKey is deprecated and can be absent from
        // Broadcast Upload samples. On the affected iOS 16 ReplayKit path,
        // portrait buffers arrive upright while an untagged wide buffer is
        // stored with its display origin inverted. Normalize that fallback at
        // the sender so native and browser receivers get one stable value.
        return pixelWidth > pixelHeight ? 3 : 1
    }
}
