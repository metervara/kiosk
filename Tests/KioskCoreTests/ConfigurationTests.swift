import XCTest
@testable import KioskCore

final class ConfigurationTests: XCTestCase {
    func testBareWebsiteGetsHTTPS() throws {
        XCTAssertEqual(try WebsiteAddress.parse("  example.com/exhibit  ").absoluteString, "https://example.com/exhibit")
    }

    func testLocalHTTPAndPorts() throws {
        XCTAssertEqual(try WebsiteAddress.parse("http://localhost:8080/").host, "localhost")
        XCTAssertEqual(try WebsiteAddress.parse("localhost:8080").port, 8080)
        XCTAssertEqual(try WebsiteAddress.parse("192.168.1.2:8080").port, 8080)
        XCTAssertEqual(try WebsiteAddress.parse("http://[::1]:8080/").port, 8080)
    }

    func testRejectsInvalidAndPrivilegedAddresses() {
        for value in ["", " ", "https://", "https://example.com/a b", "file:///etc/passwd", "javascript:alert(1)",
                      "data:text/html,Hello", "mailto:hello@example.com", "chrome://settings", "ftp://example.com",
                      "https://name:secret@example.com", "http://example.com:0", "http://example.com:99999"] {
            XCTAssertThrowsError(try WebsiteAddress.parse(value), value)
        }
    }

    func testPreservesPathQueryAndFragment() throws {
        let value = "https://example.com/show?mode=visitor#start"
        XCTAssertEqual(try WebsiteAddress.parse(value).absoluteString, value)
    }

    func testRestrictedNavigationUsesExactHosts() throws {
        let policy = try NavigationPolicy(home: URL(string: "https://example.com")!, additionalHosts: "www.example.com, login.example.org")
        for address in ["https://example.com/other", "http://example.com:8080", "https://WWW.EXAMPLE.COM", "https://login.example.org"] {
            XCTAssertTrue(policy.allows(URL(string: address)!), address)
        }
        for address in ["https://example.com.attacker.com", "https://attacker-example.com", "https://sub.example.com", "https://elsewhere.com"] {
            XCTAssertFalse(policy.allows(URL(string: address)!), address)
        }
    }

    func testExternalProtocolsDeniedEvenWithoutHostRestriction() throws {
        let policy = try NavigationPolicy(home: URL(string: "https://example.com")!, additionalHosts: "", restricted: false)
        XCTAssertTrue(policy.allows(URL(string: "https://other.example")!))
        for address in ["mailto:hello@example.com", "file:///tmp/data", "javascript:alert(1)", "tel:123", "data:text/html,test", "https://user:pass@example.com"] {
            XCTAssertFalse(policy.allows(URL(string: address)!), address)
        }
    }

    func testAdditionalHostsRejectAmbiguousEntries() {
        for entry in ["*.example.com", "https://example.com", "example.com/path", "example.com:80", "user@example.com", "example.com?x", "example.com#x"] {
            XCTAssertThrowsError(try NavigationPolicy(home: URL(string: "https://example.com")!, additionalHosts: entry), entry)
        }
    }

    func testConfigurationBounds() throws {
        var c = KioskConfiguration()
        c.website = "example.com"
        XCTAssertEqual(try c.validated().website, "https://example.com")
        c.idleSeconds = -1
        XCTAssertThrowsError(try c.validated())
        c.idleSeconds = 0
        c.refreshMinutes = -1
        XCTAssertThrowsError(try c.validated())
        c.refreshMinutes = 0
        c.loadTimeout = 14
        XCTAssertThrowsError(try c.validated())
        c.loadTimeout = 301
        XCTAssertThrowsError(try c.validated())
    }

    func testFullScreenIsOptionalAndPreviewAlwaysOverridesIt() {
        var configuration = KioskConfiguration()
        XCTAssertTrue(configuration.usesFullScreen(preview: false))
        XCTAssertFalse(configuration.usesFullScreen(preview: true))
        configuration.fullScreen = false
        XCTAssertFalse(configuration.usesFullScreen(preview: false))
        XCTAssertFalse(configuration.usesFullScreen(preview: true))
    }

    func testSettingsFromBeforeFullScreenOptionRetainTheirValues() throws {
        let data = Data(#"{"website":"https://museum.example","idleSeconds":90,"persistentSession":true}"#.utf8)
        let configuration = try JSONDecoder().decode(KioskConfiguration.self, from: data)
        XCTAssertEqual(configuration.website, "https://museum.example")
        XCTAssertEqual(configuration.idleSeconds, 90)
        XCTAssertTrue(configuration.persistentSession)
        XCTAssertTrue(configuration.fullScreen)
        XCTAssertFalse(configuration.automaticDoNotDisturb)
    }

    func testAutomaticDNDOptionSurvivesSaving() throws {
        var configuration = KioskConfiguration()
        configuration.automaticDoNotDisturb = true
        let data = try JSONEncoder().encode(configuration)
        XCTAssertTrue(try JSONDecoder().decode(KioskConfiguration.self, from: data).automaticDoNotDisturb)
    }

    func testEditableDefaultsDecode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Model/Defaults.plist"))
        XCTAssertEqual(try PropertyListDecoder().decode(KioskConfiguration.self, from: data), KioskConfiguration())
    }
}
