import XCTest
@testable import EarshotCore

final class PromptBuilderTests: XCTestCase {
    let spanish = Languages.language(code: "es")!
    let french = Languages.language(code: "fr")!

    func testStyleResolution() {
        XCTAssertEqual(PromptStyle.automatic.resolved(forModel: "mlx-community/translategemma-12b-it-4bit"), .translateGemma)
        XCTAssertEqual(PromptStyle.automatic.resolved(forModel: "TranslateGemma-27B"), .translateGemma)
        XCTAssertEqual(PromptStyle.automatic.resolved(forModel: "Qwen3-30B-A3B-Instruct-2507-4bit"), .chat)
        XCTAssertEqual(PromptStyle.chat.resolved(forModel: "translategemma-4b-it"), .chat)
        XCTAssertEqual(PromptStyle.translateGemma.resolved(forModel: "qwen"), .translateGemma)
    }

    func testChatMessagesCarryContextAsEarlierTurns() {
        let history = [
            TranslationTurn(source: "Hola", translation: "Bonjour"),
            TranslationTurn(source: "", translation: "skipped"),
        ]
        let messages = PromptBuilder.chatMessages(text: "¿Qué tal?", source: spanish, target: french, history: history, instructions: "Use formal register.")
        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertTrue(messages[0].text.contains("into French"))
        XCTAssertTrue(messages[0].text.contains("of Spanish speech"))
        XCTAssertTrue(messages[0].text.hasSuffix("Use formal register."))
        XCTAssertEqual(messages[1].text, "Hola")
        XCTAssertEqual(messages[2].text, "Bonjour")
        XCTAssertEqual(messages[3].text, "¿Qué tal?")
    }

    func testSystemPromptWithoutSourceLanguage() {
        let prompt = PromptBuilder.systemPrompt(source: nil, target: Languages.language(code: "zh-Hans")!)
        XCTAssertTrue(prompt.contains("into Simplified Chinese"))
        XCTAssertFalse(prompt.contains(" speech:"))
    }

    func testTranslateGemmaPrompt() {
        let prompt = PromptBuilder.translateGemmaPrompt(text: "Hola, ¿qué tal?", source: spanish, target: Languages.language(code: "zh-Hant")!)
        XCTAssertTrue(prompt.hasPrefix("<start_of_turn>user\nYou are a professional Spanish (es) to Traditional Chinese (zh-TW) translator."))
        XCTAssertTrue(prompt.contains("Produce only the Traditional Chinese translation, without any additional explanations or commentary."))
        XCTAssertTrue(prompt.contains("Please translate the following Spanish text into Traditional Chinese:\n\n\nHola, ¿qué tal?<end_of_turn>"))
        XCTAssertTrue(prompt.hasSuffix("<end_of_turn>\n<start_of_turn>model\n"))
        XCTAssertFalse(prompt.contains("<bos>"))

        let unknownSource = PromptBuilder.translateGemmaInstruction(text: "x", source: nil, target: french)
        XCTAssertTrue(unknownSource.hasPrefix("You are a professional translator into French (fr)."))
    }

    func testMaxTokens() {
        XCTAssertEqual(PromptBuilder.maxTokens(forSource: "hi"), 64)
        XCTAssertEqual(PromptBuilder.maxTokens(forSource: String(repeating: "a", count: 100)), 232)
        XCTAssertEqual(PromptBuilder.maxTokens(forSource: String(repeating: "a", count: 5_000)), 1024)
    }
}

final class TextCleanupTests: XCTestCase {
    func testWhisperHallucinationsAreNoise() {
        let noise = [
            "Thank you for watching!",
            " Thanks for watching. ",
            "[Music]",
            "(upbeat music)",
            "♪ ♪ ♪",
            "you",
            "You.",
            "Sous-titres réalisés par la communauté d'Amara.org",
            "Субтитры сделал DimaTorzok",
            "ご視聴ありがとうございました",
            "...",
            "",
        ]
        for text in noise {
            XCTAssertTrue(TextCleanup.isNoise(text), text)
            XCTAssertEqual(TextCleanup.cleanTranscript(text), "", text)
        }
        let speech = ["Thank you.", "Hello there", "42", "Where are you going?", "Bonjour à tous"]
        for text in speech {
            XCTAssertFalse(TextCleanup.isNoise(text), text)
        }
    }

    func testCleanTranscript() {
        XCTAssertEqual(TextCleanup.cleanTranscript("  Hello   [Music]  world \n"), "Hello world")
        XCTAssertEqual(TextCleanup.cleanTranscript("(applause) We did it."), "We did it.")
    }

    func testVisibleModelOutputHidesReasoning() {
        XCTAssertEqual(TextCleanup.visibleModelOutput("<think>Let me see…</think>Bonjour"), "Bonjour")
        XCTAssertEqual(TextCleanup.visibleModelOutput("<think>still thinking"), "")
        XCTAssertEqual(TextCleanup.visibleModelOutput("plan the answer</think>\nHola"), "\nHola")
        XCTAssertEqual(TextCleanup.visibleModelOutput("Hola<end_of_turn>\n<start_of_turn>user"), "Hola")
        XCTAssertEqual(TextCleanup.visibleModelOutput("Ciao<|im_end|>"), "Ciao")
        XCTAssertEqual(TextCleanup.visibleModelOutput("A<think>x</think>B<think>y</think>C"), "ABC")
    }

    func testCleanTranslation() {
        XCTAssertEqual(TextCleanup.cleanTranslation("Translation: Bonjour"), "Bonjour")
        XCTAssertEqual(TextCleanup.cleanTranslation("French translation: Salut tout le monde"), "Salut tout le monde")
        XCTAssertEqual(TextCleanup.cleanTranslation("\"Bonjour\""), "Bonjour")
        XCTAssertEqual(TextCleanup.cleanTranslation("“Hallo”"), "Hallo")
        XCTAssertEqual(TextCleanup.cleanTranslation("He said \"hi\" twice"), "He said \"hi\" twice")
        XCTAssertEqual(TextCleanup.cleanTranslation("<think>hmm</think>\n  Guten Tag  "), "Guten Tag")
        XCTAssertEqual(TextCleanup.cleanTranslation("  Line one\nline two "), "Line one line two")
    }

    func testCollapseRepetitions() {
        XCTAssertEqual(TextCleanup.collapseRepetitions("I think I think I think I think so"), "I think so")
        XCTAssertEqual(TextCleanup.collapseRepetitions("no no no"), "no no no")
        XCTAssertEqual(TextCleanup.collapseRepetitions("no no no no no"), "no")
        XCTAssertEqual(
            TextCleanup.collapseRepetitions("We go now. We go now. We go now. Bye"),
            "We go now. Bye"
        )
        XCTAssertEqual(TextCleanup.collapseRepetitions("a perfectly normal sentence here"), "a perfectly normal sentence here")
    }
}

final class LanguagesTests: XCTestCase {
    func testCodesAreUnique() {
        let codes = Languages.all.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
    }

    func testLookups() {
        XCTAssertEqual(Languages.find("French")?.code, "fr")
        XCTAssertEqual(Languages.find("fr")?.code, "fr")
        XCTAssertEqual(Languages.find("Deutsch")?.code, "de")
        XCTAssertEqual(Languages.find("zh-hant")?.code, "zh-Hant")
        XCTAssertNil(Languages.find("klingon"))
        XCTAssertEqual(Languages.language(recognized: "zh")?.code, "zh-Hans")
        XCTAssertEqual(Languages.language(recognized: "english")?.code, "en")
        XCTAssertEqual(Languages.language(recognized: "PT")?.code, "pt")
        XCTAssertNil(Languages.language(recognized: ""))
    }

    func testDefaultTarget() {
        XCTAssertEqual(Languages.defaultTarget(preferredLanguages: ["en-GB"]).code, "es")
        XCTAssertEqual(Languages.defaultTarget(preferredLanguages: ["de-DE", "en"]).code, "en")
        XCTAssertEqual(Languages.defaultTarget(preferredLanguages: []).code, "es")
    }

    func testListsAreSorted() {
        XCTAssertEqual(Languages.targets.map(\.name), Languages.targets.map(\.name).sorted())
        XCTAssertTrue(Languages.sources.allSatisfy { $0.whisperCode != nil })
        XCTAssertEqual(Languages.language(code: "fr")?.menuTitle, "French — Français")
        XCTAssertEqual(Languages.english.menuTitle, "English")
    }
}

final class TranscriptExporterTests: XCTestCase {
    func entries() -> [TranscriptEntry] {
        [
            TranscriptEntry(segmentID: 1, startTime: 3.5, duration: 2, sourceText: "Hola", sourceLanguage: "es", translations: ["en": "Hello"], targetLanguages: ["en"], state: .done),
            TranscriptEntry(segmentID: 2, startTime: 3723.456, duration: 0.2, sourceText: "Adiós", sourceLanguage: "es", targetLanguages: ["en"], state: .failed("x")),
            TranscriptEntry(segmentID: 3, startTime: 4000, duration: 1, targetLanguages: ["en"], state: .transcribing),
        ]
    }

    func testTimestamps() {
        XCTAssertEqual(TranscriptExporter.srtTimestamp(3723.456), "01:02:03,456")
        XCTAssertEqual(TranscriptExporter.srtTimestamp(-1), "00:00:00,000")
        XCTAssertEqual(TranscriptExporter.clock(65), "1:05")
        XCTAssertEqual(TranscriptExporter.clock(3725), "1:02:05")
    }

    func testSRT() {
        let srt = TranscriptExporter.export(entries(), as: .srt)
        XCTAssertEqual(srt, "1\n00:00:03,500 --> 00:00:05,500\nHello\nHola\n\n2\n01:02:03,456 --> 01:02:04,456\nAdiós\n")
    }

    func testPlainTextAndMarkdown() {
        XCTAssertEqual(TranscriptExporter.export(entries(), as: .plainText), "Hello\n    (Hola)\nAdiós\n")
        XCTAssertEqual(TranscriptExporter.export(entries(), as: .plainText, includeSource: false), "Hello\nAdiós\n")
        let markdown = TranscriptExporter.export(entries(), as: .markdown)
        XCTAssertTrue(markdown.hasPrefix("# Earshot transcript\n"))
        XCTAssertTrue(markdown.contains("**0:03** · ES → EN\n\n> Hola\n\nHello\n"))
    }

    func bilingualEntries() -> [TranscriptEntry] {
        [
            TranscriptEntry(segmentID: 1, startTime: 3.5, duration: 2, sourceText: "Hello", sourceLanguage: "en", translations: ["en": "Hello", "uk": "Привіт"], targetLanguages: ["en", "uk"], state: .done),
            TranscriptEntry(segmentID: 2, startTime: 12, duration: 1, sourceText: "Привет", sourceLanguage: "ru", translations: ["en": "Hi", "uk": "Привіт"], targetLanguages: ["en", "uk"], state: .done),
        ]
    }

    func testBilingualPlainText() {
        XCTAssertEqual(
            TranscriptExporter.export(bilingualEntries(), as: .plainText),
            "EN: Hello\nUK: Привіт\n\nEN: Hi\nUK: Привіт\n    (Привет)\n"
        )
        XCTAssertEqual(
            TranscriptExporter.export(bilingualEntries(), as: .plainText, includeSource: false),
            "EN: Hello\nUK: Привіт\n\nEN: Hi\nUK: Привіт\n"
        )
    }

    func testBilingualMarkdown() {
        let markdown = TranscriptExporter.export(bilingualEntries(), as: .markdown)
        XCTAssertTrue(markdown.contains("**0:03** · EN → EN, UK\n\n**EN** Hello\n\n**UK** Привіт\n"), markdown)
        XCTAssertTrue(markdown.contains("**0:12** · RU → EN, UK\n\n> Привет\n\n**EN** Hi\n\n**UK** Привіт\n"), markdown)
    }

    func testBilingualSRT() {
        XCTAssertEqual(
            TranscriptExporter.export(bilingualEntries(), as: .srt, includeSource: false),
            "1\n00:00:03,500 --> 00:00:05,500\nHello\nПривіт\n\n2\n00:00:12,000 --> 00:00:13,000\nHi\nПривіт\n"
        )
        XCTAssertEqual(
            TranscriptExporter.export(bilingualEntries(), as: .srt),
            "1\n00:00:03,500 --> 00:00:05,500\nHello\nПривіт\n\n2\n00:00:12,000 --> 00:00:13,000\nHi\nПривіт\nПривет\n"
        )
    }

    func testBilingualEntryWithoutTranslationsShowsTheOriginalOnce() {
        let untranslated = [
            TranscriptEntry(segmentID: 1, startTime: 3.5, duration: 2, sourceText: "Hola", sourceLanguage: "es", targetLanguages: ["en", "uk"], state: .failed("x")),
        ]
        XCTAssertEqual(TranscriptExporter.export(untranslated, as: .markdown), "# Earshot transcript\n\n**0:03** · ES → EN, UK\n\nHola\n")
        XCTAssertEqual(TranscriptExporter.export(untranslated, as: .plainText), "Hola\n")
        XCTAssertEqual(TranscriptExporter.export(untranslated, as: .srt), "1\n00:00:03,500 --> 00:00:05,500\nHola\n")
    }
}
