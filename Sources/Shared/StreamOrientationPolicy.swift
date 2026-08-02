import Foundation

enum StreamOrientationPolicy {
    static func resolve(
        orientation: UInt32,
        pixelWidth: Int,
        pixelHeight: Int,
        mode: StreamOrientationMode,
        direction: StreamRotationDirection
    ) -> UInt32 {
        guard pixelWidth > 0,
              pixelHeight > 0,
              (1...8).contains(orientation) else {
            return orientation
        }

        let quarterTurn = (5...8).contains(orientation)
        let displayWidth = quarterTurn ? pixelHeight : pixelWidth
        let displayHeight = quarterTurn ? pixelWidth : pixelHeight
        let needsQuarterTurn: Bool
        switch mode {
        case .automatic:
            return orientation
        case .landscape:
            needsQuarterTurn = displayWidth < displayHeight
        case .portrait:
            needsQuarterTurn = displayWidth > displayHeight
        }
        guard needsQuarterTurn else { return orientation }

        // Compose a quarter-turn with the already repaired ReplayKit EXIF
        // orientation. Only metadata changes: encoded pixels keep their
        // original aspect ratio and are never stretched.
        switch direction {
        case .left:
            switch orientation {
            case 1: return 8
            case 2: return 5
            case 3: return 6
            case 4: return 7
            case 5: return 4
            case 6: return 1
            case 7: return 2
            case 8: return 3
            default: return orientation
            }
        case .right:
            switch orientation {
            case 1: return 6
            case 2: return 7
            case 3: return 8
            case 4: return 5
            case 5: return 2
            case 6: return 3
            case 7: return 4
            case 8: return 1
            default: return orientation
            }
        }
    }
}
