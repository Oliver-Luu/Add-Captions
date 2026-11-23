import AVFoundation
import Foundation
import Testing
@testable import Add_Captions

/// Words 0.3 s long with 0.1 s between them, starting at `from`.
private func words(_ text: String, from: Double = 0) -> [TimedWord] {
    text.split(separator: " ").enumerated().map { index, word in
        let start = from + Double(index) * 0.4
        return TimedWord(start: start, end: start + 0.3, text: String(word))
    }
}

@Suite("Words to captions")
struct WordsToCaptionsTests {
    @Test func aSentenceEndStartsANewCaption() {
        let captions = WordsToCaptions.captions(from: words("Hello there. How are you?"))
        #expect(captions.map(\.text) == ["Hello there.", "How are you?"])
    }

    @Test func aPauseStartsANewCaption() {
        let captions = WordsToCaptions.captions(from: words("first part", from: 0) + words("second part", from: 3))
        #expect(captions.map(\.text) == ["first part", "second part"])
        #expect(captions[0].start == 0)
        #expect(captions[1].start == 3)
    }

    @Test func longSpeechIsSplitWithinTheLimits() {
        let text = Array(repeating: "word", count: 80).joined(separator: " ")
        let captions = WordsToCaptions.captions(from: words(text))
        #expect(captions.count > 1)
        for caption in captions {
            #expect(caption.text.count <= WordsToCaptions.maxLineLength * WordsToCaptions.maxLines)
            #expect(caption.end - caption.start <= WordsToCaptions.maxDuration + WordsToCaptions.linger + 0.001)
            #expect(WordsToCaptions.lines(caption.text).count <= WordsToCaptions.maxLines)
        }
        // No word lost or repeated.
        #expect(captions.map(\.text).joined(separator: " ") == text)
    }

    @Test func captionsLingerButNeverOverlap() {
        let captions = WordsToCaptions.captions(from: words("One. Two. Three."))
        for (caption, next) in zip(captions, captions.dropFirst()) {
            #expect(caption.end <= next.start)
        }
        // The last one stays up at least the minimum time.
        let last = try! #require(captions.last)
        #expect(last.end - last.start >= WordsToCaptions.minDuration - 0.001)
    }

    @Test func sentenceEnds() {
        #expect(WordsToCaptions.endsSentence("done."))
        #expect(WordsToCaptions.endsSentence("really?"))
        #expect(WordsToCaptions.endsSentence("stop!\""))
        #expect(WordsToCaptions.endsSentence("wait…"))
        #expect(!WordsToCaptions.endsSentence("however,"))
        #expect(!WordsToCaptions.endsSentence(""))
    }

    @Test func linesAreBalanced() {
        #expect(WordsToCaptions.lines("Short line") == ["Short line"])
        let lines = WordsToCaptions.lines("This caption is long enough that it needs to go onto two lines")
        #expect(lines.count == 2)
        #expect(abs(lines[0].count - lines[1].count) < 12)
        #expect(lines.joined(separator: " ") == "This caption is long enough that it needs to go onto two lines")
        #expect(WordsToCaptions.lines("   ").isEmpty)
    }

    @Test func findsTheCaptionAtATime() {
        let captions = [
            Caption(start: 1, end: 2, text: "a"),
            Caption(start: 3, end: 4, text: "b"),
        ]
        #expect(WordsToCaptions.caption(at: 0.5, in: captions) == nil)
        #expect(WordsToCaptions.caption(at: 1, in: captions)?.text == "a")
        #expect(WordsToCaptions.caption(at: 2.5, in: captions) == nil)
        #expect(WordsToCaptions.caption(at: 3.9, in: captions)?.text == "b")
        #expect(WordsToCaptions.caption(at: 4, in: captions) == nil)
        #expect(WordsToCaptions.caption(at: 1, in: []) == nil)
    }

    @Test func timestamps() {
        #expect(WordsToCaptions.timestamp(0, separator: ",") == "00:00:00,000")
        #expect(WordsToCaptions.timestamp(3725.5, separator: ",") == "01:02:05,500")
        #expect(WordsToCaptions.timestamp(59.9996, separator: ".") == "00:01:00.000")
        #expect(WordsToCaptions.timestamp(-1, separator: ",") == "00:00:00,000")
    }

    @Test func srtFile() {
        let srt = WordsToCaptions.srt([
            Caption(start: 1, end: 2.5, text: "Hello."),
            Caption(start: 3, end: 4, text: "This caption is long enough that it needs to go onto two lines"),
        ])
        #expect(srt.hasPrefix("1\n00:00:01,000 --> 00:00:02,500\nHello.\n\n2\n00:00:03,000 --> 00:00:04,000\n"))
        #expect(srt.components(separatedBy: "\n").count == 9)
    }

    @Test func webVTTFile() {
        let vtt = WordsToCaptions.webVTT([Caption(start: 1, end: 2.5, text: "Hello.")])
        #expect(vtt == "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello.\n")
    }
}

@Suite("Transcription pieces")
struct TranscriptionPiecesTests {
    @Test func runsBecomeWords() {
        let words = AudioToTranscription.words(from: [
            (text: "Hello", start: 1.0, end: 1.4),
            (text: ",", start: nil, end: nil),
            (text: " world", start: 1.5, end: 2.0),
            (text: ".", start: nil, end: nil),
        ], phraseStart: 1, phraseEnd: 2)
        #expect(words == [
            TimedWord(start: 1.0, end: 1.4, text: "Hello,"),
            TimedWord(start: 1.5, end: 2.0, text: "world."),
        ])
    }

    @Test func runsWithoutTimesUseThePhraseStart() {
        let words = AudioToTranscription.words(from: [(text: "Hi", start: nil, end: nil)], phraseStart: 4, phraseEnd: 5)
        #expect(words == [TimedWord(start: 4, end: 4, text: "Hi")])
    }

    /// Regression: a lecture failed with "OSStatus error -39" because its audio file reported one frame
    /// more than it held, and reading at the real end threw. That must count as the end of the audio.
    @Test func readingPastTheEndIsTheEndNotAnError() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let samples = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1000))
            samples.frameLength = 1000
            try file.write(from: samples)
        }
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4000))
        // A short read returns what there is.
        #expect(try AudioToTranscription.readChunk(of: file, into: buffer, frameCount: 4000))
        #expect(buffer.frameLength == 1000)
        // Asking again at the end (what an over-long `length` leads to) ends quietly instead of throwing.
        #expect(try AudioToTranscription.readChunk(of: file, into: buffer, frameCount: 1) == false)
    }

    @Test func shortVideosAreOnePiece() {
        #expect(AudioToTranscription.evenCuts(duration: 120, pieces: 4).isEmpty)
        let plan = AudioToTranscription.plan(duration: 120, cuts: [])
        #expect(plan == [AudioToTranscription.Piece(start: 0, end: 120, keepFrom: -.infinity, keepUntil: .infinity)])
    }

    @Test func longVideosAreSplitAndJoinedWithoutRepeats() {
        let cuts = AudioToTranscription.evenCuts(duration: 3600, pieces: 4)
        #expect(cuts == [900, 1800, 2700])
        let plan = AudioToTranscription.plan(duration: 1200, cuts: [600])
        // Both pieces heard the word at 610 (the second through its lead-in): only one keeps it.
        let first = [TimedWord(start: 590, end: 591, text: "a"), TimedWord(start: 610, end: 611, text: "b")]
        let second = [TimedWord(start: 590, end: 591, text: "a"), TimedWord(start: 610, end: 611, text: "b"),
                      TimedWord(start: 700, end: 701, text: "c")]
        #expect(AudioToTranscription.merge(plan, [first, second]).map(\.text) == ["a", "b", "c"])
    }
}
