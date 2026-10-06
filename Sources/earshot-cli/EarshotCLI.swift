import EarshotCore
import Foundation

/// `earshot-cli` runs a WAV file through the same pipeline the app uses and
/// prints the translated transcript — handy for trying models in MLX Studio.
@main
struct EarshotCLI {
    static let usage = """
    USAGE: earshot-cli [options] <recording.wav>

    Translates speech in a WAV file using an OpenAI-compatible server
    (MLX Studio's gateway by default), exactly like the Earshot app does.

    OPTIONS:
      --server URL          Server for translation (default http://127.0.0.1:8080)
      --speech-server URL   Separate server for /v1/audio/transcriptions (default: --server)
      --api-key KEY         Bearer token, if the server wants one
      --speech-model NAME   Speech model (default mlx-community/whisper-large-v3-turbo-asr-fp16)
      --model NAME          Translation model (default: first model the server lists)
      --from LANG           Spoken language code or name, or "auto" (default auto)
      --to LANG[,LANG]      Target language(s), comma-separated, e.g. en,uk (default en)
      --style STYLE         automatic | chat | translategemma (default automatic)
      --context N           Earlier utterances given to chat models (default 2)
      --sensitivity X       Voice detection sensitivity 0...1 (default 0.5)
      --continuous          Cut audio into fixed 12 s chunks instead of detecting pauses
      --preview             Also run live previews (shown with --verbose)
      --realtime            Feed audio at real speed, like a microphone
      --verbose             Print every pipeline event
      --list-models         List the server's models and exit
      --languages           List language codes and exit
      -h, --help            Show this help
    """

    static func main() async {
        var options = Options()
        do {
            options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            printError("error: \(error)\n\n\(usage)")
            exit(64)
        }

        if options.showHelp {
            print(usage)
            return
        }
        if options.listLanguages {
            for language in Languages.targets {
                print("\(language.code.padding(toLength: 8, withPad: " ", startingAt: 0)) \(language.menuTitle)")
            }
            return
        }

        guard let server = ServerEndpoint(string: options.server, apiKey: options.apiKey) else {
            printError("error: invalid --server \(options.server)")
            exit(64)
        }
        let speechServer = options.speechServer.flatMap { ServerEndpoint(string: $0, apiKey: options.apiKey) } ?? server

        if options.listModels {
            do {
                let models = try await OpenAICompatibleClient().listModels(at: server)
                models.forEach { print($0) }
                if models.isEmpty { printError("(no models loaded)") }
            } catch {
                printError("error: \(error.localizedDescription)")
                exit(1)
            }
            return
        }

        guard let path = options.file else {
            printError("error: no WAV file given\n\n\(usage)")
            exit(64)
        }
        var targets: [Language] = []
        for name in options.target.split(separator: ",") {
            guard let language = Languages.find(String(name)) else {
                printError("error: unknown language \"\(name)\" (see --languages)")
                exit(64)
            }
            targets.append(language)
        }
        guard !targets.isEmpty else {
            printError("error: --to needs at least one language")
            exit(64)
        }
        var source: Language?
        if options.source.lowercased() != "auto" {
            guard let language = Languages.find(options.source) else {
                printError("error: unknown language \"\(options.source)\" (see --languages)")
                exit(64)
            }
            source = language
        }

        let audio: [Float]
        do {
            let decoded = try WAVFile.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            audio = Resampler.resample(decoded.samples, from: decoded.sampleRate, to: 16_000)
        } catch {
            printError("error: could not read \(path): \(error.localizedDescription)")
            exit(66)
        }

        var segmenter = SegmenterConfiguration()
        segmenter.applySensitivity(options.sensitivity)
        segmenter.continuous = options.continuous
        let configuration = PipelineConfiguration(
            targetLanguages: targets,
            sourceLanguage: source,
            speechEndpoint: speechServer,
            translationEndpoint: server,
            speechModel: options.speechModel,
            translationModel: options.model,
            promptStyle: options.style,
            contextTurns: options.context,
            livePreview: options.preview ? .originalAndTranslation : .off,
            segmenter: segmenter
        )

        let pipeline = TranslationPipeline(configuration: configuration)
        let printer = Task { await printEvents(pipeline.events, verbose: options.verbose) }
        await pipeline.start()
        await pipeline.prepare()

        let chunk = 1_600  // 100 ms
        var offset = 0
        while offset < audio.count {
            let end = min(offset + chunk, audio.count)
            pipeline.ingest(Array(audio[offset..<end]))
            offset = end
            if options.realtime {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await pipeline.finish()
        let summary = await printer.value
        if summary.completed == 0, summary.issues > 0 {
            exit(1)
        }
    }

    struct Summary {
        var completed = 0
        var issues = 0
    }

    static func printEvents(_ events: AsyncStream<PipelineEvent>, verbose: Bool) async -> Summary {
        var summary = Summary()
        for await event in events {
            switch event {
            case .ready(let model):
                printError("▸ translating with \(model)")
            case .issue(let issue):
                summary.issues += 1
                printError("⚠︎ [\(issue.stage.rawValue)] \(issue.message)")
            case .entryUpdated(let entry) where entry.isFinished:
                print("[\(TranscriptExporter.clock(entry.startTime))] (\(entry.sourceLanguage ?? "?")) \(entry.sourceText)")
                if case .failed(let reason) = entry.state {
                    print("       ✗ \(reason)")
                } else {
                    summary.completed += 1
                    if entry.targetLanguages.count > 1 {
                        for code in entry.targetLanguages {
                            print("       \(code.uppercased()) → \(entry.translation(code))")
                        }
                    } else {
                        print("       → \(entry.primaryTranslation)")
                    }
                }
            case .preview(let preview?) where verbose:
                let translated = preview.translations.keys.sorted()
                    .map { "\($0.uppercased()): \(preview.translations[$0] ?? "")" }
                    .joined(separator: " · ")
                printError("  … \(preview.sourceText)\(translated.isEmpty ? "" : " → \(translated)")")
            default:
                if verbose { printError("  · \(event)") }
            }
        }
        return summary
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

struct Options {
    var server = "http://127.0.0.1:8080"
    var speechServer: String?
    var apiKey: String?
    var speechModel = PipelineConfiguration.defaultSpeechModel
    var model = ""
    var source = "auto"
    var target = "en"
    var style = PromptStyle.automatic
    var context = 2
    var sensitivity = 0.5
    var continuous = false
    var preview = false
    var realtime = false
    var verbose = false
    var listModels = false
    var listLanguages = false
    var showHelp = false
    var file: String?

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var remaining = arguments[...]
        func value(for flag: String) throws -> String {
            guard let next = remaining.popFirst() else { throw ParseError(description: "\(flag) needs a value") }
            return next
        }
        while let argument = remaining.popFirst() {
            switch argument {
            case "--server": options.server = try value(for: argument)
            case "--speech-server": options.speechServer = try value(for: argument)
            case "--api-key": options.apiKey = try value(for: argument)
            case "--speech-model": options.speechModel = try value(for: argument)
            case "--model": options.model = try value(for: argument)
            case "--from": options.source = try value(for: argument)
            case "--to": options.target = try value(for: argument)
            case "--style":
                let raw = try value(for: argument).lowercased()
                guard let style = PromptStyle.allCases.first(where: { $0.rawValue.lowercased() == raw }) else {
                    throw ParseError(description: "unknown style \(raw)")
                }
                options.style = style
            case "--context":
                guard let count = Int(try value(for: argument)), count >= 0 else { throw ParseError(description: "--context needs a number") }
                options.context = count
            case "--sensitivity":
                guard let level = Double(try value(for: argument)) else { throw ParseError(description: "--sensitivity needs a number") }
                options.sensitivity = level
            case "--continuous": options.continuous = true
            case "--preview": options.preview = true
            case "--realtime": options.realtime = true
            case "--verbose", "-v": options.verbose = true
            case "--list-models": options.listModels = true
            case "--languages": options.listLanguages = true
            case "--help", "-h": options.showHelp = true
            default:
                if argument.hasPrefix("-"), argument != "-" {
                    throw ParseError(description: "unknown option \(argument)")
                }
                options.file = argument
            }
        }
        return options
    }
}
