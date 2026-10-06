import Foundation

/// Models worth loading in MLX Studio, with rough memory needs.
struct ModelSuggestion: Identifiable, Hashable {
    enum Role: String {
        case speech = "Speech"
        case translation = "Translation"
    }

    let id: String
    let role: Role
    let name: String
    let memoryGB: Double
    let note: String
}

enum ModelCatalog {
    /// Speech models MLX Studio's bundled mlx-audio can load (downloaded on first use).
    static let speech: [ModelSuggestion] = [
        ModelSuggestion(id: "mlx-community/whisper-large-v3-turbo-asr-fp16", role: .speech, name: "Whisper large-v3 turbo", memoryGB: 1.6,
                        note: "Recommended. 99 languages, fast enough for live use."),
        ModelSuggestion(id: "mlx-community/parakeet-tdt-0.6b-v3", role: .speech, name: "Parakeet TDT 0.6B v3", memoryGB: 1.2,
                        note: "Fastest. English and 24 European languages."),
    ]

    /// Hugging Face repositories to download in MLX Studio.
    static let translation: [ModelSuggestion] = [
        ModelSuggestion(id: "mlx-community/translategemma-12b-it-4bit", role: .translation, name: "TranslateGemma 12B (4-bit)", memoryGB: 7,
                        note: "Recommended. Purpose-built translator, quick and very good."),
        ModelSuggestion(id: "mlx-community/translategemma-27b-it-4bit", role: .translation, name: "TranslateGemma 27B (4-bit)", memoryGB: 16,
                        note: "Best quality; a little more latency."),
        ModelSuggestion(id: "mlx-community/translategemma-4b-it-4bit", role: .translation, name: "TranslateGemma 4B (4-bit)", memoryGB: 2.5,
                        note: "Fastest translator, good for fast talkers."),
        ModelSuggestion(id: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit", role: .translation, name: "Qwen3 30B-A3B Instruct (4-bit)", memoryGB: 17,
                        note: "General model: follows extra instructions (tone, glossary)."),
    ]

    static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }
}
