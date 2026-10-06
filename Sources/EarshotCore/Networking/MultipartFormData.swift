import Foundation

/// Builds a `multipart/form-data` body.
public struct MultipartFormData {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "earshot-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(escape(name))\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    public mutating func addFile(name: String, filename: String, contentType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(escape(name))\"; filename=\"\(escape(filename))\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    /// The complete body, including the closing boundary.
    public func finalized() -> Data {
        var result = body
        result.append(contentsOf: Array("--\(boundary)--\r\n".utf8))
        return result
    }

    private mutating func append(_ string: String) {
        body.append(contentsOf: Array(string.utf8))
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
