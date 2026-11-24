# Libraries, Toolkits, and Frameworks

Add Captions has no third-party dependencies and calls no network services. Everything below ships
with Apple's SDKs.

| Framework | Used in | What for |
|---|---|---|
| SwiftUI | `MyApp.swift`, `Frontend/` | All UI, the file importer and file mover, `ShareLink` |
| Observation | `Frontend/CaptionSession.swift` | `@Observable` session state |
| AVFoundation | `Backend/`, `Frontend/EditorView.swift` | Reading video, splitting out audio (`AVAssetExportSession`), reading audio (`AVAudioFile`), the burn-in video composition (`AVVideoComposition(applyingFiltersTo:)`), writing the subtitle track (`AVAssetWriter`, `AVMutableComposition`), playback (`AVPlayer`) |
| AVKit | `Frontend/EditorView.swift` | `VideoPlayer`. Linked explicitly with `-framework AVKit` (`OTHER_LDFLAGS`): without it the app crashed the first time the player appeared, because only AVKit's SwiftUI overlay was linked |
| Speech | `Backend/AudioToTranscription.swift` | On-device English transcription with word timings (`SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`) |
| CoreMedia | `Backend/CaptionsToVideo.swift` | tx3g format descriptions and sample buffers for the subtitle track |
| Core Image | `Backend/CaptionsToVideo.swift` | Compositing caption images over each video frame |
| CoreText, CoreGraphics | `Backend/CaptionsToVideo.swift` | Drawing caption text, boxes and outlines |
| UniformTypeIdentifiers | `Frontend/ContentView.swift` | Accepting only video files |
| Foundation | everywhere | Files, strings, timing |
| Swift Testing | `Add CaptionsTests/` | Unit and end-to-end tests (test target only) |

Test-only: `AVSpeechSynthesizer` (AVFoundation) speaks test sentences, and `AVAssetImageGenerator`
reads frames back to check burned-in captions.

## Tooling

- `Tools/make_icon.swift` writes the Icon Composer app icon (`AppIcon.icon`: icon.json + an SVG layer) and optional PNG previews with Core Graphics and ImageIO (run with `swift`, not part of the app)

- Xcode 27.2, Swift 6.4 toolchain (Swift 5 language mode, main-actor default isolation)
- Targets: macOS, iOS, and visionOS 27.2
