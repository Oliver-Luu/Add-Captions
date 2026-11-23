import Foundation
import Observation

/// One video being captioned: transcribing it, the captions the user edits, and saving the result.
@Observable final class CaptionSession {
    enum Phase: Equatable {
        /// No video yet.
        case idle
        /// Listening to the video; `progress` says how far along.
        case transcribing
        /// Captions are ready to look over, edit and save.
        case editing
        case failed(String)
    }

    /// What the user can save.
    enum Export: String, CaseIterable, Identifiable {
        /// A new copy of the video with the captions drawn into the picture: shows everywhere.
        case burnedIn
        /// A copy of the video with a subtitle track viewers can turn on and off; nothing re-encoded.
        case subtitleTrack
        /// A SubRip caption file, to upload next to the video (YouTube, Vimeo, video editors).
        case srt
        /// A WebVTT caption file, for web pages.
        case webVTT

        var id: Self { self }

        var title: String {
            switch self {
            case .burnedIn: "Video with Captions Burned In"
            case .subtitleTrack: "Video with Subtitle Track"
            case .srt: "Caption File (.srt)"
            case .webVTT: "Caption File (.vtt)"
            }
        }

        var detail: String {
            switch self {
            case .burnedIn: "Captions are part of the picture, so they show in every app and on every site. Takes a while: the video is re-encoded."
            case .subtitleTrack: "Fast and lossless. Viewers turn captions on in their player (QuickTime, Photos, VLC). Some sites ignore the track."
            case .srt: "Upload this next to your video on YouTube, Vimeo, or in a video editor."
            case .webVTT: "For the HTML <track> element on a web page."
            }
        }

        var systemImage: String {
            switch self {
            case .burnedIn: "film"
            case .subtitleTrack: "captions.bubble"
            case .srt, .webVTT: "doc.text"
            }
        }
    }

    typealias Transcriber = @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> [TimedWord]

    private(set) var phase: Phase = .idle
    /// True while the "choose a video" panel is open (from the start screen or File > Open Video…).
    var isChoosingVideo = false
    private(set) var videoURL: URL?
    /// The video's file name without its extension.
    private(set) var title = ""
    /// Transcription progress, 0...1.
    private(set) var progress = 0.0
    /// The captions, in time order. The editor changes their text and times directly.
    var captions: [Caption] = []
    var style = CaptionStyle()

    /// The export running now, and how far along it is (0...1).
    private(set) var exporting: Export?
    private(set) var exportProgress = 0.0
    /// The finished file, waiting for the user to choose where to keep it.
    var exportedFile: URL?
    var exportError: String?

    private let transcriber: Transcriber
    private var work: Task<Void, Never>?
    private var exportWork: Task<Void, Never>?
    /// The video's security-scoped access, held for as long as the video is open.
    private var scopedURL: URL?

    init(transcriber: @escaping Transcriber = { url, progress in
        try await AudioToTranscription.transcribe(url, progress: progress)
    }) {
        self.transcriber = transcriber
    }

    /// Opens `url` and starts captioning it, replacing any video already open.
    func open(_ url: URL) {
        startOver()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        videoURL = url
        title = url.deletingPathExtension().lastPathComponent
        phase = .transcribing
        progress = 0
        work = Task {
            do {
                let words = try await transcriber(url) { value in
                    Task { @MainActor in
                        guard self.phase == .transcribing else { return }
                        self.progress = max(self.progress, value)
                    }
                }
                try Task.checkCancellation()
                captions = WordsToCaptions.captions(from: words)
                phase = captions.isEmpty ? .failed(Self.noSpeechMessage) : .editing
            } catch is CancellationError {
                // Stopped by the user; `startOver` already reset everything.
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    static let noSpeechMessage = "No speech was heard in this video, so there is nothing to caption."

    /// Stops anything running and goes back to the start screen.
    func startOver() {
        work?.cancel()
        work = nil
        cancelExport()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        videoURL = nil
        title = ""
        captions = []
        progress = 0
        phase = .idle
        discardExport()
        exportError = nil
    }

    // MARK: Editing

    /// Adds an empty caption at `time` (seconds), lasting 2 seconds or until the next caption.
    @discardableResult
    func addCaption(at time: Double) -> Caption {
        let next = captions.first { $0.start > time }?.start ?? .infinity
        let caption = Caption(start: time, end: max(time + 0.5, min(time + 2, next)), text: "")
        captions.append(caption)
        captions.sort { $0.start < $1.start }
        return caption
    }

    func delete(_ id: Caption.ID) {
        captions.removeAll { $0.id == id }
    }

    // MARK: Saving

    /// Makes the chosen file in a temporary folder and puts it in `exportedFile` for the user to keep.
    func export(_ kind: Export) {
        guard let videoURL, exporting == nil else { return }
        exporting = kind
        exportProgress = 0
        exportError = nil
        let captions = captions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let style = style
        let output = Self.outputURL(for: kind, video: videoURL, title: title)
        exportWork = Task {
            do {
                let report: @Sendable (Double) -> Void = { value in
                    Task { @MainActor in self.exportProgress = value }
                }
                switch kind {
                case .burnedIn:
                    try await CaptionsToVideo.burnIn(captions, into: videoURL, style: style, to: output, progress: report)
                case .subtitleTrack:
                    try await CaptionsToVideo.addSubtitleTrack(captions, to: videoURL, output: output, progress: report)
                case .srt:
                    try WordsToCaptions.srt(captions).write(to: output, atomically: true, encoding: .utf8)
                case .webVTT:
                    try WordsToCaptions.webVTT(captions).write(to: output, atomically: true, encoding: .utf8)
                }
                try Task.checkCancellation()
                exportedFile = output
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: output)
            } catch {
                if !Task.isCancelled { exportError = error.localizedDescription }
                try? FileManager.default.removeItem(at: output)
            }
            exporting = nil
        }
    }

    /// True when a file can be saved now: captions are open and nothing else is being saved.
    var canExport: Bool { phase == .editing && exporting == nil }

    /// Forgets the finished file and deletes it if the user didn't move it somewhere to keep.
    func discardExport() {
        if let exportedFile { try? FileManager.default.removeItem(at: exportedFile.deletingLastPathComponent()) }
        exportedFile = nil
    }

    func cancelExport() {
        exportWork?.cancel()
        exportWork = nil
        exporting = nil
    }

    /// Where an export is written: its own temporary folder, so the file keeps a readable name
    /// ("Talk (captioned).mp4") when the user saves it.
    static func outputURL(for kind: Export, video: URL, title: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Exports/\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = title.isEmpty ? "Video" : title
        switch kind {
        case .burnedIn, .subtitleTrack:
            let ext = CaptionsToVideo.fileExtension(for: CaptionsToVideo.fileType(for: video))
            return folder.appending(path: "\(name) (captioned).\(ext)")
        case .srt: return folder.appending(path: "\(name).srt")
        case .webVTT: return folder.appending(path: "\(name).vtt")
        }
    }
}
