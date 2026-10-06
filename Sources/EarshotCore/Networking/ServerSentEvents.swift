import Foundation

/// Splits a byte stream into newline-terminated lines. Partial lines are kept
/// until the rest arrives, so multi-byte UTF-8 characters are never split.
public struct LineBuffer {
    private var buffer = Data()

    public init() {}

    /// Appends bytes and returns every line completed by them (without the line terminator).
    public mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line)
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    /// Returns whatever is left once the stream has ended.
    public mutating func finish() -> [String] {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty else { return [] }
        var line = String(decoding: buffer, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line.isEmpty ? [] : [line]
    }
}

/// One line of a `text/event-stream` response, as far as OpenAI-style streaming is concerned.
public enum ServerSentEventLine: Equatable {
    case data(String)
    case done
    case other
}

public enum ServerSentEvents {
    public static func parse(_ line: String) -> ServerSentEventLine {
        guard line.hasPrefix("data:") else { return .other }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        let trimmed = payload.trimmingCharacters(in: .whitespaces)
        if trimmed == "[DONE]" { return .done }
        if trimmed.isEmpty { return .other }
        return .data(String(payload))
    }
}
