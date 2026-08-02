import Foundation

enum StreamOrientationPolicy {
    static func resolve(
        orientation: UInt32,
        pixelWidth: Int,
        pixelHeight: Int,
        alwaysLandscape: Bool
    ) -> UInt32 {
        guard alwaysLandscape,
              pixelWidth > 0,
              pixelHeight > 0,
              (1...8).contains(orientation) else {
            return orientation
        }

        let quarterTurn = (5...8).contains(orientation)
        let displayWidth = quarterTurn ? pixelHeight : pixelWidth
        let displayHeight = quarterTurn ? pixelWidth : pixelHeight
        guard displayWidth <= displayHeight else { return orientation }

        // Compose one clockwise quarter-turn with the resolved EXIF
        // orientation. Landscape samples are untouched, including the
        // device-specific 180-degree repair performed upstream.
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
