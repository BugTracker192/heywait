import Foundation
import UIKit

enum BrowserWebApp {
    static let name = "Screen Share"

    static func manifest(accessKey: String) -> Data {
        let key = PairingSecret.normalize(accessKey)
        let manifest: [String: Any] = [
            "name": name,
            "short_name": name,
            "description": "Local Screen Share viewer",
            "id": "/?k=\(key)",
            "start_url": "/?k=\(key)",
            "scope": "/",
            "display": "standalone",
            "orientation": "any",
            "background_color": "#000000",
            "theme_color": "#000000",
            "icons": [
                [
                    "src": "/icon.png",
                    "sizes": "512x512",
                    "type": "image/png",
                    "purpose": "any maskable"
                ]
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
    }

    static let iconPNG: Data = {
        let size = CGSize(width: 512, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let graphics = context.cgContext
            UIColor(red: 6 / 255, green: 24 / 255, blue: 47 / 255, alpha: 1).setFill()
            graphics.fill(CGRect(origin: .zero, size: size))

            let rear = UIBezierPath(
                roundedRect: CGRect(x: 218, y: 48, width: 238, height: 310),
                cornerRadius: 44
            )
            UIColor.white.setStroke()
            rear.lineWidth = 25
            rear.stroke()

            let front = UIBezierPath(
                roundedRect: CGRect(x: 56, y: 166, width: 306, height: 298),
                cornerRadius: 50
            )
            UIColor(red: 44 / 255, green: 211 / 255, blue: 219 / 255, alpha: 1).setStroke()
            front.lineWidth = 25
            front.stroke()

            UIColor.white.setStroke()
            let wirelessArcs: [(CGFloat, CGFloat)] = [(102, 22), (66, 20)]
            for (radius, lineWidth) in wirelessArcs {
                let arc = UIBezierPath(
                    arcCenter: CGPoint(x: 185, y: 338),
                    radius: radius,
                    startAngle: -.pi / 2,
                    endAngle: 0,
                    clockwise: true
                )
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                arc.stroke()
            }

            UIColor(red: 44 / 255, green: 211 / 255, blue: 219 / 255, alpha: 1).setFill()
            graphics.fillEllipse(in: CGRect(x: 159, y: 365, width: 40, height: 40))
        }

        return image.pngData() ?? Data()
    }()
}
