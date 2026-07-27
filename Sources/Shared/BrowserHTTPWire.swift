import Foundation

enum BrowserHTTPWire {
    static func headerBlock(_ lines: [String]) -> Data {
        precondition(
            lines.allSatisfy { !$0.contains("\r") && !$0.contains("\n") },
            "HTTP header lines must not contain line breaks"
        )
        return Data((lines + ["", ""]).joined(separator: "\r\n").utf8)
    }
}
