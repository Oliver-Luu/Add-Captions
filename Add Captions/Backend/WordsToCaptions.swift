import Foundation

/// One caption: the text on screen from `start` to `end` (seconds from the start of the video).
nonisolated struct Caption: Identifiable, Sendable, Codable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    /// One line of text; it is wrapped onto at most `WordsToCaptions.maxLines` lines when shown.
    var text: String
}

/// Groups recognized words into captions that are comfortable to read, and writes caption files.
///
/// The limits follow common subtitling practice: at most two lines of about 42 characters, on screen
/// for no more than 7 seconds and no less than about one second, with a new caption at the end of each
/// sentence and at each pause in the speech.
nonisolated enum WordsToCaptions {
    static let maxLineLength = 42
    static let maxLines = 2
    static let maxDuration = 7.0
    static let minDuration = 1.0
    /// A silence at least this long between two words starts a new caption.
    static let pauseGap = 0.8
    /// How long a caption stays up after its last word, unless the next caption starts sooner.
    static let linger = 0.5

    /// The captions for `words` (in time order).
    static func captions(from words: [TimedWord]) -> [Caption] {
        var groups: [[TimedWord]] = []
        var current: [TimedWord] = []
        for word in words {
            if let first = current.first, let last = current.last {
                let text = (current + [word]).map(\.text).joined(separator: " ")
                let tooLong = text.count > maxLineLength * maxLines
                let tooSlow = word.end - first.start > maxDuration
                let paused = word.start - last.end >= pauseGap
                let sentenceEnded = endsSentence(last.text) && current.count >= 1
                if tooLong || tooSlow || paused || sentenceEnded {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }

        var captions = groups.map { group in
            Caption(start: group[0].start, end: group[group.count - 1].end, text: group.map(\.text).joined(separator: " "))
        }
        // Linger after the last word and stay up at least `minDuration`, but never overlap the next one.
        for index in captions.indices {
            let next = index + 1 < captions.count ? captions[index + 1].start : .infinity
            let wanted = max(captions[index].end + linger, captions[index].start + minDuration)
            captions[index].end = max(captions[index].end, min(wanted, next))
        }
        return captions
    }

    /// True when a word finishes a sentence ("done." "really?" "stop!" "end.\"").
    static func endsSentence(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
        guard let last = trimmed.last else { return false }
        return ".?!…".contains(last)
    }

    /// `text` split onto at most `maxLines` lines of about `maxLineLength` characters, with the lines as
    /// even in length as the words allow (a short top line over a long one is hard to read).
    static func lines(_ text: String, maxLength: Int = maxLineLength) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let whole = words.joined(separator: " ")
        if whole.count <= maxLength { return [whole] }
        // The break that makes the longer of the two lines as short as possible.
        var best = (longest: Int.max, index: 1)
        for index in 1..<words.count {
            let top = words[..<index].joined(separator: " ").count
            let bottom = words[index...].joined(separator: " ").count
            let longest = max(top, bottom)
            if longest < best.longest { best = (longest, index) }
        }
        return [words[..<best.index].joined(separator: " "), words[best.index...].joined(separator: " ")]
    }

    /// The caption showing at `time`, if any.
    static func caption(at time: Double, in captions: [Caption]) -> Caption? {
        // Binary search: the last caption that starts at or before `time`.
        var low = 0, high = captions.count
        while low < high {
            let mid = (low + high) / 2
            if captions[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let candidate = captions[low - 1]
        return time < candidate.end ? candidate : nil
    }

    // MARK: Files

    /// A SubRip (.srt) file: the format nearly every video player and site accepts.
    static func srt(_ captions: [Caption]) -> String {
        captions.enumerated().map { index, caption in
            "\(index + 1)\n\(timestamp(caption.start, separator: ",")) --> \(timestamp(caption.end, separator: ","))\n"
                + lines(caption.text).joined(separator: "\n") + "\n"
        }.joined(separator: "\n")
    }

    /// A WebVTT (.vtt) file: the format web pages use with the HTML `<track>` element.
    static func webVTT(_ captions: [Caption]) -> String {
        "WEBVTT\n\n" + captions.map { caption in
            "\(timestamp(caption.start, separator: ".")) --> \(timestamp(caption.end, separator: "."))\n"
                + lines(caption.text).joined(separator: "\n") + "\n"
        }.joined(separator: "\n")
    }

    /// `HH:MM:SS,mmm` (SRT) or `HH:MM:SS.mmm` (WebVTT).
    static func timestamp(_ seconds: Double, separator: String) -> String {
        let total = Int((max(0, seconds) * 1000).rounded())
        let hours = total / 3_600_000, minutes = total / 60_000 % 60, secs = total / 1000 % 60, millis = total % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, millis)
    }
}
