import Darwin
import Foundation

enum LocalBrowserLink {
    static func currentURL(accessKey: String) -> URL? {
        guard let address = wifiIPv4Address() else { return nil }
        return url(host: address, accessKey: accessKey)
    }

    static func url(host: String, accessKey: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        // The ReplayKit extension owns the live viewer. Point the QR straight
        // at that process instead of a temporary listener in the Sender app:
        // iOS suspends the containing app while the broadcast sheet/game is
        // active, which made an otherwise valid link turn white and time out.
        components.port = Int(AppConstants.browserViewerPort)
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "k", value: PairingSecret.normalize(accessKey))
        ]
        return components.url
    }

    private static func wifiIPv4Address() -> String? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let address = cursor {
            defer { cursor = address.pointee.ifa_next }
            guard let socketAddress = address.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET),
                  String(cString: address.pointee.ifa_name) == "en0" else {
                continue
            }

            let flags = Int32(address.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
