# Earshot

**Live translation of everything your Mac hears, as captions that float above everything, using local models in [MLX Studio](https://github.com/jjang-ai/mlxstudio).**

Earshot listens to the default microphone, cuts the audio into utterances, has
MLX Studio transcribe them with Whisper, then streams a translation from the LLM you
have loaded (TranslateGemma, Qwen, …). Nothing leaves your Mac.

- **Captions that never get in the way.** They float above every app, full-screen presentations included, and clicks pass straight through them, so you can keep driving your slides.
- **Lives in the menu bar.** Every control is in the menu-bar icon's menu, and global shortcuts work even while another app is in front.
- **Five display styles:** Subtitles, Teleprompter (with a mirror mode for beam-splitter glass), News Ticker, Transcript and Spotlight.
- **Translation only, or side by side.** By default only the translation is shown, and a faint "…" stands in until each sentence is translated, so the original never flashes up first. Turn on **Show Original Side by Side** (menu-bar menu → Display Style) to get what was heard on the left and the translation on the right; the ticker stacks two bands and the transcript lines its columns up row by row.
- **Two languages at once.** Pin a second language (**Languages → Also Translate Into**) and everything heard is shown in both, one column each: in a room of English and Ukrainian speakers, each group reads its own side. Speech already in one of the pinned languages appears there as-is, so most sentences need only one translation. Leave **Speech Language** on Detect Automatically so Whisper recognises both groups.
- **Your choice of type and colour.** Use any installed font, size, weight, alignment and line spacing. Pick one of the themes (Midnight, Glass, Paper, Broadcast, Cinema, Shadow, Terminal) or set your own colours, and adjust background opacity.
- **Live previews.** Words appear while the speaker is still talking, then settle when they pause.
- **Export** the transcript as text, bilingual Markdown or SRT subtitles.

---

## Quick start

### 1. Set up MLX Studio

1. Install MLX Studio (App Store or [GitHub releases](https://github.com/jjang-ai/mlxstudio)). It needs macOS 14.5+ and Apple Silicon.
2. Download and load a **translation model**. On an M3 Max with 64 GB, start with `mlx-community/translategemma-12b-it-4bit`.
   For TranslateGemma, open the session's settings first and set **Multimodal Support (VLM)** to **Force Off**
   (in the *Multimodal & Video* section). MLX Studio otherwise loads Gemma 3 models with its vision loader,
   which fails on these text-only downloads; Earshot only needs text.
3. Leave the **API gateway** enabled. It's on by default at `http://127.0.0.1:8080` (Server → API).

You don't need to load Whisper yourself. The engine behind MLX Studio (vMLX) loads it
the first time Earshot sends audio. That first request takes a minute or two while
roughly 1.6 GB downloads; after that it's fast.

### 2. Build and run Earshot

You need macOS 14 or later and Xcode 15+ (or just the Command Line Tools, Swift 5.9+).

```sh
git clone https://github.com/gwhren/earshot.git
cd earshot
make run          # builds build/Earshot.app, ad-hoc signed, and opens it
make install      # optional: copies it to ~/Applications
```

### 3. Talk

Click the captions icon in the menu bar and choose **Start Listening** (or press **⌃⌥⌘L** from any app),
then allow microphone access. Choose the language to translate into under **Languages → Translate Into**.

---

## Models for an M3 Max with 64 GB

Everything below fits in memory alongside Whisper, with lots of room to spare.

| Role | Model (search in MLX Studio) | Memory | Why |
|---|---|---|---|
| Speech | `mlx-community/whisper-large-v3-turbo-asr-fp16` *(default)* | ~1.6 GB | 99 languages, quick enough for live use |
| Speech | `mlx-community/parakeet-tdt-0.6b-v3` | ~1.2 GB | Fastest; English and 24 European languages |
| Translation | `mlx-community/translategemma-12b-it-4bit` | ~7 GB | **Recommended.** Purpose-built translator; fast and very good |
| Translation | `mlx-community/translategemma-27b-it-4bit` | ~16 GB | Best quality, a little more latency |
| Translation | `mlx-community/translategemma-4b-it-4bit` | ~2.5 GB | Lowest latency |
| Translation | `mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit` | ~17 GB | General model (fast mixture-of-experts); follows extra instructions such as tone or a glossary |

Set the speech model in **Settings → Models**, where there is also a list of these recommendations
with copy buttons. Use the full names above: MLX Studio's short aliases such as `whisper-large-v3-turbo`
point at older downloads that its speech engine can't load ("Processor not found").

---

## Using the captions

The captions float above everything, on every Space and over full-screen apps, and ignore the mouse,
so Google Slides, Preview or whatever is underneath keeps working. Everything else is in the menu-bar icon's menu.

| Shortcut (works from any app) | |
|---|---|
| **⌃⌥⌘L** | Start or stop listening |
| **⌃⌥⌘C** | Show or hide the captions |
| **⌃⌥⌘= / ⌃⌥⌘-** | Bigger or smaller text |

- **Move & Resize Captions…** (in the menu, or Settings → Captions) unlocks the captions. Drag them anywhere, including onto a projector, and drag the corner grip to resize them. Click **Done** or press Esc when you're finished; they also lock again by themselves after 30 seconds.
- **Problems** such as MLX Studio not running show as a one-line notice on the captions and a warning icon in the menu bar. The menu has the fix (Retry, Open Settings…).
- When you aren't listening and there's nothing to show, the captions are invisible.
- **Glass and Cinema themes** outline the text. With background opacity near zero you get clean subtitles over whatever is behind them.
- **The Shadow theme** is just white text with a drop shadow: no background, labels or divider, so only the words sit over your slides.

---

## How it works

```
 mic ──AVAudioEngine──► 16 kHz mono ──► SpeechSegmenter (voice detection, pauses, 12 s cap)
                                              │ utterance / live preview
                                              ▼
                        POST /v1/audio/transcriptions ─── MLX Studio ─── Whisper (mlx-audio)
                                              │ text + detected language
                                              ▼
            POST /v1/completions (TranslateGemma) or /v1/chat/completions (others), streamed
                                              │ tokens
                                              ▼
                       Subtitles · Teleprompter · Ticker · Transcript · Spotlight
```

- **Voice detection** tracks the room's noise floor, so there's nothing to calibrate. It ends an utterance after a pause (0.7 s by default) and cuts monologues at the quietest moment before 12 s.
- **Ordering and catch-up.** Utterances are processed strictly in order. If the model falls behind, queued ones are merged into a single request so the display catches up.
- **Live previews** re-transcribe the sentence in progress about once a second, but only when nothing finished is waiting.
- **Clean-up.** Whisper's usual hallucinations over silence ("Thanks for watching!", "Amara.org" credits, `[Music]`) are dropped. Reasoning models are asked not to think (`enable_thinking: false`), and any `<think>` text is hidden anyway.

### MLX Studio details Earshot works around

- **Speech routing.** vMLX reads the speech model from the **query string**, while MLX Studio's gateway routes requests by the form's `model` field. Earshot sends both. If the gateway replies "model not found", Earshot routes the audio through your translation model's session instead, and that engine loads Whisper on demand.
- **TranslateGemma prompts.** TranslateGemma's chat template rejects plain-text messages. Earshot sends it the model's native prompt through `/v1/completions`, and falls back to structured chat content if a server has no completions endpoint.

### Other servers

Anything OpenAI-compatible works. In **Settings → Models** you can use a second server just for speech:

- **vMLX directly:** `pip install 'vmlx[audio]'` then `vmlx serve mlx-community/translategemma-12b-it-4bit`, which serves both speech and translation on port 8000.
- **Translation elsewhere:** LM Studio (port 1234) or `mlx_lm.server` for translation, plus `mlx_audio.server` or vMLX for speech.

---

## Command-line tool

`earshot-cli` runs a WAV file through the same pipeline. It's useful for trying models or prompts:

```sh
swift build -c release --product earshot-cli
say -v Monica -o hola.aiff "Hola a todos. Bienvenidos a la demostración de hoy."
afconvert -f WAVE -d LEI16@16000 hola.aiff hola.wav
.build/release/earshot-cli --to en hola.wav
.build/release/earshot-cli --to en,uk hola.wav          # English and Ukrainian, one line each
.build/release/earshot-cli --model mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit --to ja --realtime --preview --verbose hola.wav
.build/release/earshot-cli --list-models
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Can't reach 127.0.0.1:8080" | Open MLX Studio, load a model, and check that the API gateway is on. For a plain `vmlx serve`, set the server to `http://127.0.0.1:8000`. |
| "can't transcribe speech (mlx-audio is missing)" | MLX Studio ships mlx-audio. For vMLX run `pip install 'vmlx[audio]'`. |
| MLX Studio can't start TranslateGemma: `VisionConfig.__init__() missing 6 required positional arguments` | MLX Studio loads Gemma 3 models with its vision loader. In the session's settings set **Multimodal Support (VLM)** to **Force Off** and restart it. If that doesn't stick, add `"language_model_only": true,` to the model's `config.json` (under `~/.mlxstudio/models` or `~/.cache/huggingface/hub`). |
| `Transcription failed (HTTP 500): Processor not found` | The speech model is an older Whisper download without tokenizer files. In **Settings → Models** set the speech model to `mlx-community/whisper-large-v3-turbo-asr-fp16`. |
| First words take ages | The speech model is downloading on first use. Watch MLX Studio's logs. |
| Nothing is picked up | Check the input in System Settings → Sound, raise **Sensitivity** in Settings → Listening, or try **Continuous mode** in noisy rooms. |
| Microphone permission never appears | Run the app from `build/Earshot.app` or `~/Applications`, not the bare binary. To reset: `tccutil reset Microphone com.gwhren.earshot`. |
| "Earshot is damaged" after downloading the CI build | The CI build is ad-hoc signed. Run `xattr -dr com.apple.quarantine Earshot.app`, or build it yourself. |
| The captions are gone | Choose **Show Captions** in the menu-bar menu, or press ⌃⌥⌘C. If they were on a display that's been unplugged, they move back to the main screen. |
| A shortcut does nothing | Another app, or a macOS keyboard shortcut, may be using the same keys. Settings → Captions marks any that Earshot couldn't register, but macOS doesn't always report a clash. |

---

## Development

```sh
make test           # unit tests (EarshotCore; also run on Linux)
make fake-server    # a stand-in MLX Studio on :8080 (pip install fastapi uvicorn python-multipart)
./scripts/e2e-cli.sh
```

| Path | What's there |
|---|---|
| `Sources/EarshotCore/` | Platform-independent engine: segmenter, WAV, OpenAI-compatible client (streaming SSE), prompts, clean-up, pipeline |
| `Sources/Earshot/` | The macOS app: caption overlay and settings windows (AppKit), menu-bar menu, global shortcuts, SwiftUI display styles and settings |
| `Sources/earshot-cli/` | Command-line front end |
| `Tools/fake_mlx_studio.py` | Fake server reproducing MLX Studio's and vMLX's API quirks |
| `Tools/overlay_probe.swift` | Checks the caption window from outside: its level, its frame, and that clicks pass through it |

CI (`.github/workflows/ci.yml`) runs the core tests on Linux. On macOS it builds
the app, runs the end-to-end check, and uploads `Earshot.zip` as an artifact.

---

## License

MIT. See [LICENSE](LICENSE).
