import Foundation

public struct KioskConfiguration: Codable, Equatable {
    public var website = ""
    public var additionalHosts = ""
    public var restrictNavigation = true
    public var idleSeconds = 120
    public var refreshMinutes = 0
    public var loadTimeout = 45
    public var displayID: UInt32 = 0
    public var fullScreen = true
    public var automaticDoNotDisturb = false
    public var startAutomatically = false
    public var recoverApplication = true
    public var persistentSession = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case website, additionalHosts, restrictNavigation, idleSeconds, refreshMinutes, loadTimeout
        case displayID, fullScreen, automaticDoNotDisturb, startAutomatically, recoverApplication, persistentSession
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        website = try values.decodeIfPresent(String.self, forKey: .website) ?? website
        additionalHosts = try values.decodeIfPresent(String.self, forKey: .additionalHosts) ?? additionalHosts
        restrictNavigation = try values.decodeIfPresent(Bool.self, forKey: .restrictNavigation) ?? restrictNavigation
        idleSeconds = try values.decodeIfPresent(Int.self, forKey: .idleSeconds) ?? idleSeconds
        refreshMinutes = try values.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? refreshMinutes
        loadTimeout = try values.decodeIfPresent(Int.self, forKey: .loadTimeout) ?? loadTimeout
        displayID = try values.decodeIfPresent(UInt32.self, forKey: .displayID) ?? displayID
        fullScreen = try values.decodeIfPresent(Bool.self, forKey: .fullScreen) ?? fullScreen
        automaticDoNotDisturb = try values.decodeIfPresent(Bool.self, forKey: .automaticDoNotDisturb) ?? automaticDoNotDisturb
        startAutomatically = try values.decodeIfPresent(Bool.self, forKey: .startAutomatically) ?? startAutomatically
        recoverApplication = try values.decodeIfPresent(Bool.self, forKey: .recoverApplication) ?? recoverApplication
        persistentSession = try values.decodeIfPresent(Bool.self, forKey: .persistentSession) ?? persistentSession
    }

    public func usesFullScreen(preview: Bool) -> Bool { fullScreen && !preview }

    public func validated() throws -> KioskConfiguration {
        var result = self
        result.website = try WebsiteAddress.parse(website).absoluteString
        _ = try NavigationPolicy(home: WebsiteAddress.parse(website),
                                 additionalHosts: additionalHosts,
                                 restricted: restrictNavigation)
        guard (0...86_400).contains(idleSeconds) else {
            throw ConfigurationError("Idle reset must be between 0 and 86,400 seconds.")
        }
        guard (0...10_080).contains(refreshMinutes) else {
            throw ConfigurationError("Scheduled refresh must be between 0 and 10,080 minutes.")
        }
        guard (15...300).contains(loadTimeout) else {
            throw ConfigurationError("Load timeout must be between 15 and 300 seconds.")
        }
        return result
    }
}

public struct ConfigurationError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum WebsiteAddress {
    public static func parse(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else {
            throw ConfigurationError("Enter a website address without spaces, such as https://example.com.")
        }
        // Recognize bare host:port addresses without treating their port as a URL scheme.
        let address: String
        if value.contains("://") {
            address = value
        } else if let prefix = value.split(separator: ":", maxSplits: 1).first,
                  value.contains(":"), !prefix.contains("."), prefix != "localhost",
                  !value.hasPrefix("[") {
            let suffix = value.dropFirst(prefix.count + 1).split(separator: "/").first ?? ""
            guard UInt16(suffix) != nil else {
                throw ConfigurationError("Only http:// and https:// websites are supported.")
            }
            address = "https://" + value
        } else {
            address = "https://" + value
        }
        guard let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = components.url else {
            throw ConfigurationError("Use an HTTP or HTTPS address with a valid host and no embedded username or password.")
        }
        return url
    }
}

public struct NavigationPolicy {
    public let allowedHosts: Set<String>
    public let restricted: Bool

    public init(home: URL, additionalHosts: String, restricted: Bool = true) throws {
        var hosts = Set<String>()
        if let host = home.host { hosts.insert(Self.canonicalHost(host)) }
        for entry in additionalHosts.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            let host = String(entry)
            guard !host.contains("/"), !host.contains(":"), !host.contains("*"),
                  !host.contains("@"), !host.contains("?"), !host.contains("#"),
                  let url = URL(string: "https://" + host),
                  let parsed = url.host, Self.canonicalHost(parsed) == Self.canonicalHost(host),
                  !Self.canonicalHost(parsed).isEmpty else {
                throw ConfigurationError("Additional hosts must be exact host names, such as www.example.com. Separate them with commas; omit paths and wildcards.")
            }
            hosts.insert(Self.canonicalHost(parsed))
        }
        self.allowedHosts = hosts
        self.restricted = restricted
    }

    public func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil, let host = url.host else { return false }
        return !restricted || allowedHosts.contains(Self.canonicalHost(host))
    }

    private static func canonicalHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
