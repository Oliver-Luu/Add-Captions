import AVFoundation
import Speech

/// One spoken word and when it is heard, in seconds from the start of the video.
nonisolated struct TimedWord: Sendable, Codable, Equatable {
    var start: Double
    var end: Double
    /// The word as recognized, with any punctuation after it ("Hello," or "today.").
    var text: String
}

/// Transcribes a video's audio entirely on device with Apple's SpeechAnalyzer, word by word.
///
/// Adapted from Lecture Me Faster's `AudioToTranscription`: the same splitting into pieces and joining at
/// pauses, but it keeps every word's start and end time, because captions need both, and it always
/// recognizes English.
nonisolated enum AudioToTranscription {
    enum Failure: LocalizedError {
        case noAudio

        var errorDescription: String? { "This video has no sound to caption." }
    }

    /// The English the recognizer listens for: the device's own English when it is set to a variant of
    /// English the recognizer supports (en-GB, en-AU…), otherwise American English.
    static func englishLocale(for current: Locale = .current) async -> Locale {
        if current.language.languageCode == .english,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: current) {
            return supported
        }
        return Locale(identifier: "en-US")
    }

    /// Every word spoken in `url`, in order, transcribed in up to `pieces` parts at once (see `plan`).
    @concurrent
    static func transcribe(
        _ url: URL,
        pieces: Int = maxPieces,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedWord] {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw Failure.noAudio }
        let duration = try await asset.load(.duration).seconds

        let isVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        let audioURL = isVideo ? try await separateAudio(from: asset) : url
        defer { if isVideo { try? FileManager.default.removeItem(at: audioURL) } }

        let locale = await englishLocale()
        let installer = SpeechTranscriber(locale: locale, preset: .transcription)
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [installer]) {
            try await download.downloadAndInstall()
        }

        // Each cut moves to the nearest pause, so no word is split between two pieces.
        let cuts = evenCuts(duration: duration, pieces: pieces).map { quietestMoment(in: audioURL, near: $0) }
        let ranges = plan(duration: duration, cuts: cuts)
        let tracker = ProgressTracker(count: ranges.count, report: progress)
        let results = try await withThrowingTaskGroup(of: (Int, [TimedWord]).self) { group in
            for (index, piece) in ranges.enumerated() {
                group.addTask {
                    let words = try await transcribe(audioURL, from: piece.start, to: piece.end, locale: locale) {
                        tracker.update(index, $0)
                    }
                    return (index, words)
                }
            }
            var out = [[TimedWord]](repeating: [], count: ranges.count)
            for try await (index, words) in group { out[index] = words }
            return out
        }
        // A stopped transcription can end early with only part of the speech; that isn't a transcript.
        try Task.checkCancellation()
        progress(1)
        return merge(ranges, results)
    }

    // MARK: One recording in pieces

    /// The most pieces one recording is split into, and the shortest a piece may be. Lecture Me Faster
    /// measured these (2026-11-13): 4 pieces cut a 73-minute lecture from 58 s to 19 s, with the word
    /// error rate moving from 4.53% to 4.76% on 13 minutes of scripted speech.
    static let maxPieces = 4
    static let minimumPieceSeconds = 300.0
    /// Each piece starts this long before its own range, so the recognizer has context at the cut; the
    /// words from the lead-in are dropped.
    static let leadIn = 30.0
    /// Each piece runs this long past its range, so a sentence across the cut is finished.
    static let overhang = 20.0

    struct Piece: Equatable, Sendable {
        /// The audio this piece transcribes.
        var start: Double
        var end: Double
        /// The part of the timeline this piece is responsible for.
        var keepFrom: Double
        var keepUntil: Double
    }

    /// Where pieces meet, evenly spaced, before any move to a pause: up to `pieces` equal ranges, none
    /// shorter than `minimumPieceSeconds`.
    static func evenCuts(duration: Double, pieces: Int) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let count = max(1, min(pieces, maxPieces, Int(duration / minimumPieceSeconds)))
        return (1..<count).map { duration * Double($0) / Double(count) }
    }

    /// The pieces for the given cuts (in order, inside the recording).
    static func plan(duration: Double, cuts: [Double]) -> [Piece] {
        guard duration.isFinite, duration > 0 else { return [Piece(start: 0, end: 0, keepFrom: -.infinity, keepUntil: .infinity)] }
        let edges = [0.0] + cuts + [duration]
        return (0..<(edges.count - 1)).map { index in
            let from = edges[index], until = edges[index + 1]
            let isLast = index == edges.count - 2
            return Piece(
                start: index == 0 ? 0 : max(0, from - leadIn),
                end: isLast ? duration : min(duration, until + overhang),
                keepFrom: index == 0 ? -.infinity : from,
                keepUntil: isLast ? .infinity : until
            )
        }
    }

    /// Joins the pieces word by word: each piece contributes exactly the words that start inside its own
    /// range, so every word near a cut comes from one piece only, never twice and never missing.
    static func merge(_ pieces: [Piece], _ results: [[TimedWord]]) -> [TimedWord] {
        zip(pieces, results).flatMap { piece, words in
            words.filter { $0.start >= piece.keepFrom && $0.start < piece.keepUntil }
        }
    }

    /// How far a cut may move to reach a pause, and how long the quiet stretch it looks for is.
    static let pauseSearchSeconds = 30.0
    static let pauseLength = 0.5

    /// The middle of the quietest `pauseLength` within `pauseSearchSeconds` of `time`: a gap between
    /// words, so no word is cut in two. Returns `time` when the audio can't be read.
    static func quietestMoment(in url: URL, near time: Double) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return time }
        let format = file.processingFormat
        let rate = format.sampleRate
        let from = max(0, AVAudioFramePosition((time - pauseSearchSeconds) * rate))
        let until = min(file.length, AVAudioFramePosition((time + pauseSearchSeconds) * rate))
        guard until > from, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(until - from)) else { return time }
        file.framePosition = from
        guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(until - from))) != nil,
              let channels = buffer.floatChannelData else { return time }
        // Loudness of each 50 ms step (mean square over every channel).
        let step = max(1, Int(rate * 0.05))
        let frames = Int(buffer.frameLength), channelCount = Int(format.channelCount)
        var energy: [Double] = []
        var position = 0
        while position + step <= frames {
            var sum = 0.0
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for index in position..<(position + step) { sum += Double(samples[index] * samples[index]) }
            }
            energy.append(sum)
            position += step
        }
        let window = max(1, Int(pauseLength / 0.05))
        guard energy.count >= window else { return time }
        // The quietest run of `window` steps; on a tie, the one nearest the planned cut.
        var running = energy[0..<window].reduce(0, +)
        var best = (sum: running, start: 0)
        func distance(_ start: Int) -> Double {
            abs(Double(from) / rate + (Double(start) + Double(window) / 2) * 0.05 - time)
        }
        if energy.count > window {
            for start in 1...(energy.count - window) {
                running += energy[start + window - 1] - energy[start - 1]
                if running < best.sum - 1e-12 || (abs(running - best.sum) <= 1e-12 && distance(start) < distance(best.start)) {
                    best = (running, start)
                }
            }
        }
        return Double(from) / rate + (Double(best.start) + Double(window) / 2) * 0.05
    }

    /// Turns one recognized phrase's text runs into words. A run with a time is a word; a run without
    /// one (a space or punctuation) belongs to the word before it. Exposed for tests.
    static func words(from runs: [(text: String, start: Double?, end: Double?)], phraseStart: Double, phraseEnd: Double) -> [TimedWord] {
        var words: [TimedWord] = []
        for run in runs {
            if let start = run.start {
                words.append(TimedWord(start: start, end: run.end ?? start, text: run.text))
            } else if !words.isEmpty {
                words[words.count - 1].text += run.text
            } else {
                words.append(TimedWord(start: phraseStart, end: phraseStart, text: run.text))
            }
        }
        return words.compactMap { word in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TimedWord(start: word.start, end: min(max(word.end, word.start), max(phraseEnd, word.start)), text: text)
        }
    }

    /// Transcribes one time range of an audio file, feeding it to the recognizer directly (no temporary
    /// file). Times in the results are on the whole file's timeline.
    static func transcribe(
        _ url: URL, from start: Double, to end: Double, locale: Locale,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedWord] {
        // The `.transcription` preset's recognition, plus each word's time.
        let preset = SpeechTranscriber.Preset.transcription
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions, attributeOptions: preset.attributeOptions.union([.audioTimeRange])
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return [] }
        // Opened before anything is started, so a file that can't be read leaves nothing running.
        let file = try AVAudioFile(forReading: url)
        let length = max(end - start, 1)
        let collector = Task {
            var out: [TimedWord] = []
            for try await result in transcriber.results {
                let runs = result.text.runs.map { run in
                    (text: String(result.text[run.range].characters),
                     start: run.audioTimeRange?.start.seconds,
                     end: run.audioTimeRange?.end.seconds)
                }
                out += words(from: runs, phraseStart: result.range.start.seconds, phraseEnd: result.range.end.seconds)
                progress(min(1, (result.range.end.seconds - start) / length))
            }
            return out
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            continuation.finish()
            collector.cancel()
            throw error
        }

        let source = file.processingFormat
        let rate = source.sampleRate
        let endFrame = min(AVAudioFramePosition(end * rate), file.length)
        file.framePosition = min(AVAudioFramePosition(start * rate), file.length)
        guard let converter = AVAudioConverter(from: source, to: target) else {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            return []
        }
        var isFirst = true
        do {
            while file.framePosition < endFrame {
                try Task.checkCancellation()
                // One second at a time.
                let count = AVAudioFrameCount(min(Int64(rate), endFrame - file.framePosition))
                guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: count),
                      try readChunk(of: file, into: input, frameCount: count) else { break }
                let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / rate) + 1024
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }
                var fed = false
                var conversionError: NSError?
                converter.convert(to: output, error: &conversionError) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return input
                }
                if let conversionError { throw conversionError }
                // The first buffer says where on the timeline this piece starts; the rest follow on.
                let time: CMTime? = isFirst ? CMTime(seconds: start, preferredTimescale: 1000) : nil
                isFirst = false
                continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: time))
            }
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    /// Core Audio's "end of file" status.
    static let endOfFile = -39

    /// Reads up to `frameCount` frames into `buffer`. Returns false at the real end of the audio.
    ///
    /// `AVAudioFile.length` can count one frame more than the file holds (measured 2026-11-22 on an
    /// 84-minute lecture's audio exported to .m4a: length 222,333,953, readable 222,333,952), so a read
    /// that starts at the real end throws "end of file" (-39). That is the end of the audio, not a failure.
    static func readChunk(of file: AVAudioFile, into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws -> Bool {
        do {
            try file.read(into: buffer, frameCount: frameCount)
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == endOfFile {
            return false
        }
        return buffer.frameLength > 0
    }

    /// Combines the progress of pieces running at once into one value.
    private final class ProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double]
        private let report: @Sendable (Double) -> Void
        init(count: Int, report: @escaping @Sendable (Double) -> Void) {
            values = Array(repeating: 0, count: count)
            self.report = report
        }
        func update(_ index: Int, _ value: Double) {
            let total = lock.withLock {
                values[index] = max(values[index], value)
                return values.reduce(0, +) / Double(values.count)
            }
            report(total)
        }
    }

    /// Splits the audio track out of a video into a temporary .m4a file.
    private static func separateAudio(from asset: AVURLAsset) async throws -> URL {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.noAudio
        }
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        try await export.export(to: output, as: .m4a)
        return output
    }
}
