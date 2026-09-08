import Foundation
import CommonCrypto
import Security

public struct OperatorCredential: Codable {
    public let salt: Data
    public let digest: Data
    public let rounds: UInt32

    public init(passcode: String) throws {
        guard passcode.count >= 6, passcode.utf8.count <= 1_024 else {
            throw ConfigurationError("Use an operator passcode of at least 6 characters (up to 1,024 bytes).")
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ConfigurationError("macOS could not generate a secure passcode salt.")
        }
        salt = Data(bytes)
        rounds = 210_000
        digest = try Self.derive(passcode, salt: salt, rounds: rounds)
    }

    public func verifies(_ passcode: String) -> Bool {
        guard salt.count == 32, digest.count == 32, (100_000...1_000_000).contains(rounds),
              passcode.utf8.count <= 1_024,
              let candidate = try? Self.derive(passcode, salt: salt, rounds: rounds) else { return false }
        return zip(candidate, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func derive(_ passcode: String, salt: Data, rounds: UInt32) throws -> Data {
        var result = [UInt8](repeating: 0, count: 32)
        let status = passcode.withCString { password in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, passcode.utf8.count,
                                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &result, result.count)
            }
        }
        guard status == kCCSuccess else { throw ConfigurationError("Could not protect the operator passcode.") }
        return Data(result)
    }
}
