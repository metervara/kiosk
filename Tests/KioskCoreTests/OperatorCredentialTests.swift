import XCTest
@testable import KioskCore

final class OperatorCredentialTests: XCTestCase {
    func testCredentialVerifiesOnlyCorrectPasscode() throws {
        let credential = try OperatorCredential(passcode: "museum-2026")
        XCTAssertTrue(credential.verifies("museum-2026"))
        XCTAssertFalse(credential.verifies("museum-2027"))
        XCTAssertFalse(credential.verifies(""))
    }

    func testSaltIsUniqueAndCredentialSurvivesPersistence() throws {
        let first = try OperatorCredential(passcode: "museum-2026")
        let second = try OperatorCredential(passcode: "museum-2026")
        XCTAssertNotEqual(first.salt, second.salt)
        XCTAssertNotEqual(first.digest, second.digest)
        let decoded = try JSONDecoder().decode(OperatorCredential.self, from: JSONEncoder().encode(first))
        XCTAssertTrue(decoded.verifies("museum-2026"))
    }

    func testPasscodesSupportUnicodeAndRejectShortValues() throws {
        let credential = try OperatorCredential(passcode: "utställning🔑")
        XCTAssertTrue(credential.verifies("utställning🔑"))
        XCTAssertThrowsError(try OperatorCredential(passcode: "12345"))
    }
}
