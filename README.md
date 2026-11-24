# Add Captions

A SwiftUI app for macOS, iOS and visionOS (27.2) that adds English captions to any video. Drop in a
video; the app listens to it on device, writes timed captions, lets you fix them while watching, and
saves the result. It is built on Lecture Me Faster's on-device transcription.

Nothing is uploaded and nothing costs money: speech recognition runs on the device with Apple's
`SpeechAnalyzer`, and the video is written with AVFoundation.

## What you can save

| Choice | What you get | When to use it |
|---|---|---|
| Video with Captions Burned In (⌘S) | A new copy of the video with captions drawn into the picture | Social media, or anywhere you can't control the player. Re-encodes the video, so it takes a while |
| Video with Subtitle Track (⇧⌘S) | A copy with an English subtitle track viewers turn on and off | QuickTime, Photos, VLC, Apple TV. Fast and lossless (nothing re-encoded). Some websites ignore the track |
| Caption File (.srt) | A SubRip file | Upload beside the video to YouTube, Vimeo, or a video editor |
| Caption File (.vtt) | A WebVTT file | The HTML `<track>` element |

Burned-in captions have three style settings: size, top or bottom, and a dark box or an outline.

## How it works

```
video ──► Backend/AudioToTranscription ──► words with start/end times
                                              │
                          Backend/WordsToCaptions ──► captions (≤2 lines × 42 chars, ≤7 s,
                                              │        new caption at each sentence end or pause)
                                    editor (Frontend/EditorView)
                                              │
                          Backend/CaptionsToVideo ──► burned-in video / subtitle track
                          Backend/WordsToCaptions ──► .srt / .vtt
```

- **`Backend/AudioToTranscription.swift`**: adapted from Lecture Me Faster. Splits the audio out of the
  video, cuts long videos into up to 4 pieces at quiet moments and transcribes them at once, then joins
  them word by word. Unlike Lecture Me Faster it keeps every word's start and end time, and always
  listens for English (the device's English variant if it has one, else US English).
- **`Backend/WordsToCaptions.swift`**: groups words into captions, wraps each onto at most two balanced
  lines, and writes SRT and WebVTT.
- **`Backend/CaptionsToVideo.swift`**: burns captions in with a Core Image video composition
  (`AVVideoComposition(applyingFiltersTo:)`), which keeps memory flat for long videos and handles
  rotated phone videos. The subtitle track is a tx3g (3GPP timed text) track written with
  `AVAssetWriter` and joined to the original tracks with a passthrough export.
- **`Frontend/`**: `CaptionSession` (state: import → transcribe → edit → export), `ContentView`
  (start screen, progress, errors), `EditorView` (player, caption list, style, save).
  The preview draws captions with the same renderer as the export, so it matches the saved video.

## Building and testing

Open `Add Captions.xcodeproj` in Xcode 27.2 and run the `Add Captions` scheme. Tests:

```sh
xcodebuild test -project "Add Captions.xcodeproj" -scheme "Add Captions" -destination 'platform=macOS'
```

The 38 tests in `Add CaptionsTests/` include end-to-end checks that generate real videos: they
synthesize speech and transcribe it, burn captions in and check the pixels of the output frames
(including a rotated portrait video), and read the subtitle track back out of `.mov` and `.mp4` files.

For checking the app by hand, Debug builds accept `-openVideo <path>` as a launch argument to open a
video straight into the editor.

The app icon is `Add Captions/AppIcon.icon`, an Icon Composer icon (a screen with a play sign and two
caption lines, a glass layer on the brand blue #2774AE), so macOS and iOS draw it with their glass
effect and in dark, clear and tinted looks. It is written by `Tools/make_icon.swift`; after changing
the drawing, regenerate it (and optional flat PNG previews):

```sh
swift Tools/make_icon.swift "Add Captions/AppIcon.icon" --png /tmp/icon-previews
```

You can also open `AppIcon.icon` in Icon Composer (inside Xcode: Xcode > Open Developer Tool) to adjust
the glass, shadow or colours by hand; rerunning the script overwrites those changes.
`LogoMark` (`Frontend/LogoMark.swift`) draws the same mark on the start screen; keep its `path(in:)`
and the script's `markPath` identical. visionOS has no icon yet (it uses its own layered format).

There are no third-party dependencies; see `Add Captions/LIBRARIES.md`. Usage help is in `HELP.md`.
