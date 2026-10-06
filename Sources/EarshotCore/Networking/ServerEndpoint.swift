import Foundation

/// Where an OpenAI-compatible server lives. The MLX Studio gateway defaults
/// to `http://127.0.0.1:8080`; a bare `vmlx serve` listens on port 8000.
public struct ServerEndpoint: Equatable, Hashable, Sendable {
    /// Base URL without a trailing slash and without the `/v1` suffix.
    public let baseURL: URL
    public var apiKey: String?

    public static let mlxStudioGateway = ServerEndpoint(uncheckedString: "http://127.0.0.1:8080")

    /// Accepts things like `127.0.0.1:8080`, `http://localhost:8000/v1/` or
    /// `https://box.local/v1`. Returns nil if no host can be found.
    public init?(string: String, apiKey: String? = nil) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        if text.lowercased().hasSuffix("/v1") {
            text.removeLast(3)
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        self.baseURL = url
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (key?.isEmpty ?? true) ? nil : key
    }

    private init(uncheckedString: String) {
        self.baseURL = URL(string: uncheckedString)!
        self.apiKey = nil
    }

    /// Builds `<base>/v1/<path>` plus query items.
    public func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/v1/" + trimmedPath
        if !query.isEmpty {
            components.queryItems = query
        }
        return components.url!
    }

    /// Human-friendly `host:port` label.
    public var displayName: String {
        var label = baseURL.host ?? baseURL.absoluteString
        if let port = baseURL.port { label += ":\(port)" }
        return label
    }
}
