import Foundation
import CryptoKit

/// 给 JS 提供 crypto-js 级别的能力，避免脚本必须依赖 npm 包。
enum CryptoBridge {

    static func md5(_ s: String, upper: Bool = false) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return hex(digest, upper: upper)
    }

    static func sha1(_ s: String, upper: Bool = false) -> String {
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        return hex(digest, upper: upper)
    }

    static func sha256(_ s: String, upper: Bool = false) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return hex(digest, upper: upper)
    }

    static func hmacSHA256(_ message: String, key: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8),
                                                  using: SymmetricKey(data: Data(key.utf8)))
        return hex(mac, upper: false)
    }

    static func base64Encode(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    static func base64Decode(_ s: String) -> String {
        guard let d = Data(base64Encoded: s, options: [.ignoreUnknownCharacters]) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    private static func hex<S: Sequence>(_ bytes: S, upper: Bool) -> String where S.Element == UInt8 {
        bytes.map { String(format: upper ? "%02X" : "%02x", $0) }.joined()
    }
}
