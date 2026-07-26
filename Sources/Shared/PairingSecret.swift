import CryptoKit
import Foundation
import Security

enum PairingSecret {
    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let rawCharacterCount = 16

    static func generate() -> String {
        let random = [UInt8](randomData(count: rawCharacterCount))
        let raw = String(random.map { alphabet[Int($0) % alphabet.count] })
        return format(raw)
    }

    static func randomData(count: Int) -> Data {
        precondition(count > 0)
        var random = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        precondition(status == errSecSuccess, "Secure random generation failed")
        return Data(random)
    }

    static func normalize(_ code: String) -> String {
        code.uppercased().filter { alphabet.contains($0) }
    }

    static func format(_ code: String) -> String {
        let normalized = normalize(code)
        return stride(from: 0, to: normalized.count, by: 4).map { offset in
            let start = normalized.index(normalized.startIndex, offsetBy: offset)
            let end = normalized.index(start, offsetBy: min(4, normalized.count - offset))
            return String(normalized[start..<end])
        }.joined(separator: "-")
    }

    static func isValid(_ code: String) -> Bool {
        normalize(code).count == rawCharacterCount
    }

    static func symmetricKey(for code: String) -> SymmetricKey {
        let normalized = normalize(code)
        let material = Data("ScreenShare/v1/pairing/\(normalized)".utf8)
        return SymmetricKey(data: SHA256.hash(data: material))
    }
}
