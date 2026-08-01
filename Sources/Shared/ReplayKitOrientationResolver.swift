import Foundation

enum ReplayKitOrientationResolver {
    static func resolve(
        attachedValue: UInt32?,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> UInt32 {
        let raw = attachedValue.flatMap { (1...8).contains($0) ? $0 : nil } ?? 1
        let quarterTurn = (5...8).contains(raw)
        let displayWidth = quarterTurn ? pixelHeight : pixelWidth
        let displayHeight = quarterTurn ? pixelWidth : pixelHeight

        guard displayWidth > displayHeight else { return raw }

        // The affected ReplayKit upload path is exactly 180 degrees wrong for
        // landscape, but it can express that landscape with any EXIF family:
        // a wide 1...4 buffer or a portrait-shaped 5...8 buffer. Compose a
        // half-turn with every landscape form so an on-screen M stays M rather
        // than becoming W on both receivers.
        switch raw {
        case 1: return 3
        case 2: return 4
        case 3: return 1
        case 4: return 2
        case 5: return 7
        case 6: return 8
        case 7: return 5
        case 8: return 6
        default: return raw
        }
    }
}
