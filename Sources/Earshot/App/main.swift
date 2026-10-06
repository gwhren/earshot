import AppKit

MainActor.assumeIsolated {
    // `Earshot --export-iconset <dir>` renders the app icon (used by scripts/build-app.sh).
    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--export-iconset"), flag + 1 < arguments.count {
        do {
            try AppIconArtwork.exportIconset(to: URL(fileURLWithPath: arguments[flag + 1]))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("icon export failed: \(error)\n".utf8))
            exit(1)
        }
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
