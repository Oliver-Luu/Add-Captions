import AVFoundation
import CoreImage
import CoreText

/// How burned-in captions look.
nonisolated struct CaptionStyle: Sendable, Codable, Equatable {
    enum Size: String, Sendable, Codable, CaseIterable, Identifiable {
        case small, medium, large
        var id: Self { self }
        var label: String { rawValue.capitalized }
        /// Text height as a share of the picture's shorter side.
        var scale: Double {
            switch self {
            case .small: 0.045
            case .medium: 0.055
            case .large: 0.07
            }
        }
    }

    enum Position: String, Sendable, Codable, CaseIterable, Identifiable {
        case bottom, top
        var id: Self { self }
        var label: String { rawValue.capitalized }
    }

    enum Look: String, Sendable, Codable, CaseIterable, Identifiable {
        /// White text on a dark box, like most streaming sites: readable on any picture.
        case boxed
        /// White text with a black outline and no box: covers less of the picture.
        case outlined
        var id: Self { self }
        var label: String { self == .boxed ? "Dark box" : "Outline" }
    }

    var size: Size = .medium
    var position: Position = .bottom
    var look: Look = .boxed

    /// The gap between the captions and the top or bottom edge, as a share of the picture's height.
    static let edgeMargin = 0.07
    /// The widest captions may be, as a share of the picture's width; longer lines shrink the text.
    static let maxWidthShare = 0.9
}

/// Draws captions as images and puts them into videos, either burned into the picture or as a subtitle
/// track that viewers can turn on and off.
nonisolated enum CaptionsToVideo {
    enum Failure: LocalizedError {
        case noVideo
        case cannotExport
        case cannotWriteSubtitles

        var errorDescription: String? {
            switch self {
            case .noVideo: "This file has no video picture to put captions on."
            case .cannotExport: "This video can't be saved in this format."
            case .cannotWriteSubtitles: "The subtitle track couldn't be written."
            }
        }
    }

    /// The file type to save as: QuickTime for .mov input, MPEG-4 for everything else.
    static func fileType(for url: URL) -> AVFileType {
        url.pathExtension.lowercased() == "mov" ? .mov : .mp4
    }

    static func fileExtension(for type: AVFileType) -> String {
        type == .mov ? "mov" : "mp4"
    }

    // MARK: Burned in

    /// Writes `video` with `captions` drawn into every frame. The picture is re-encoded; the sound is kept.
    static func burnIn(
        _ captions: [Caption], into video: URL, style: CaptionStyle, to output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: video)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw Failure.noVideo }
        let renderer = CaptionRenderer(captions: captions, style: style)
        let composition = try await AVVideoComposition(applyingFiltersTo: asset) { parameters in
            let source = parameters.sourceImage
            guard let overlay = renderer.overlay(at: parameters.compositionTime.seconds, in: source.extent) else {
                return AVCIImageFilteringResult(resultImage: source)
            }
            return AVCIImageFilteringResult(resultImage: overlay.composited(over: source).cropped(to: source.extent))
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.cannotExport
        }
        export.videoComposition = composition
        try await run(export, to: output, progress: progress)
    }

    /// Runs an export, reporting its progress, and replaces any file already at `output`.
    private static func run(
        _ export: AVAssetExportSession, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: output)
        let type = fileType(for: output)
        let watcher = Task {
            for await state in export.states(updateInterval: 0.25) {
                if case .exporting(let exportProgress) = state { progress(exportProgress.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        // Cancelling the calling task stops the export.
        try await export.export(to: output, as: type)
        progress(1)
    }

    // MARK: Subtitle track

    /// Writes `video` with `captions` as an English subtitle track. Nothing is re-encoded, so it is fast
    /// and the picture is untouched; viewers turn the captions on in their player.
    static func addSubtitleTrack(
        _ captions: [Caption], to video: URL, output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        let subtitlesURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: subtitlesURL) }
        try await writeSubtitleMovie(captions, duration: duration.seconds, to: subtitlesURL)

        let composition = AVMutableComposition()
        let wholeVideo = CMTimeRange(start: .zero, duration: duration)
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            guard let copy = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let range = try await track.load(.timeRange)
            try copy.insertTimeRange(range, of: track, at: range.start)
            copy.preferredTransform = try await track.load(.preferredTransform)
            if let language = try await track.load(.languageCode) { copy.languageCode = language }
        }
        let subtitles = AVURLAsset(url: subtitlesURL)
        guard let source = try await subtitles.loadTracks(withMediaType: .subtitle).first,
              let track = composition.addMutableTrack(withMediaType: .subtitle, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.cannotWriteSubtitles }
        try track.insertTimeRange(wholeVideo, of: source, at: .zero)
        track.languageCode = "eng"
        track.extendedLanguageTag = "en"

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.cannotExport
        }
        try await run(export, to: output, progress: progress)
    }

    /// A tx3g (3GPP timed text) sample: the text's length in UTF-8 bytes as a big-endian 16-bit number,
    /// then the text. An empty sample (length 0) clears the screen.
    static func textSample(_ text: String) -> Data {
        let bytes = Array(text.utf8.prefix(Int(UInt16.max)))
        let length = UInt16(bytes.count)
        return Data([UInt8(length >> 8), UInt8(length & 0xFF)] + bytes)
    }

    /// The samples of a subtitle track that covers `duration` seconds: each caption, and an empty sample
    /// for every gap, so the track's samples follow each other with no holes.
    static func subtitleSamples(_ captions: [Caption], duration: Double) -> [(start: Double, end: Double, text: String)] {
        var samples: [(start: Double, end: Double, text: String)] = []
        var time = 0.0
        for caption in captions.sorted(by: { $0.start < $1.start }) {
            let start = max(caption.start, time)
            let end = min(caption.end, duration)
            guard end > start else { continue }
            if start > time { samples.append((time, start, "")) }
            samples.append((start, end, WordsToCaptions.lines(caption.text).joined(separator: "\n")))
            time = end
        }
        if duration > time { samples.append((time, duration, "")) }
        return samples
    }

    /// Writes a movie that holds only a subtitle track.
    private static func writeSubtitleMovie(_ captions: [Caption], duration: Double, to url: URL) async throws {
        let format = try subtitleFormat()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
        guard writer.canAdd(input) else { throw Failure.cannotWriteSubtitles }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.cannotWriteSubtitles }
        writer.startSession(atSourceTime: .zero)
        for sample in subtitleSamples(captions, duration: duration) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let buffer = try sampleBuffer(textSample(sample.text), format: format, start: sample.start, end: sample.end)
            guard input.append(buffer) else { throw writer.error ?? Failure.cannotWriteSubtitles }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure.cannotWriteSubtitles }
    }

    /// The tx3g format: white sans-serif text, centred at the bottom, no background.
    private static func subtitleFormat() throws -> CMFormatDescription {
        let color = { (value: Int) in
            [kCMTextFormatDescriptionColor_Red: value, kCMTextFormatDescriptionColor_Green: value,
             kCMTextFormatDescriptionColor_Blue: value, kCMTextFormatDescriptionColor_Alpha: value == 0 ? 0 : 255] as CFDictionary
        }
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: color(0),
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
            ] as CFDictionary,
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                kCMTextFormatDescriptionStyle_ForegroundColor: color(255),
                kCMTextFormatDescriptionStyle_FontSize: 18,
            ] as CFDictionary,
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"] as CFDictionary,
            kCMTextFormatDescriptionExtension_HorizontalJustification: 1,  // centred
            kCMTextFormatDescriptionExtension_VerticalJustification: -1,  // bottom
        ]
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Subtitle, mediaSubType: kCMTextFormatType_3GText,
            extensions: extensions as CFDictionary, formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw Failure.cannotWriteSubtitles }
        return format
    }

    private static func sampleBuffer(_ data: Data, format: CMFormatDescription, start: Double, end: Double) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == noErr, let block else { throw Failure.cannotWriteSubtitles }
        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { throw Failure.cannotWriteSubtitles }
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: end - start, preferredTimescale: 600),
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 600), decodeTimeStamp: .invalid
        )
        var size = data.count
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &buffer
        ) == noErr, let buffer else { throw Failure.cannotWriteSubtitles }
        return buffer
    }
}

/// Makes the caption image for each moment of a video. Called from many threads at once while a video
/// is written, so it keeps only the latest caption's image, behind a lock.
nonisolated final class CaptionRenderer: @unchecked Sendable {
    private let captions: [Caption]
    private let style: CaptionStyle
    private let lock = NSLock()
    private var cached: (id: UUID, extent: CGRect, image: CIImage)?

    init(captions: [Caption], style: CaptionStyle) {
        self.captions = captions.sorted { $0.start < $1.start }
        self.style = style
    }

    /// The caption showing at `time`, drawn where it belongs in a picture filling `extent`; nil when no
    /// caption is showing.
    func overlay(at time: Double, in extent: CGRect) -> CIImage? {
        guard let caption = WordsToCaptions.caption(at: time, in: captions) else { return nil }
        if let cached = lock.withLock({ cached }), cached.id == caption.id, cached.extent == extent { return cached.image }
        guard let drawn = Self.image(for: caption.text, pictureSize: extent.size, style: style) else { return nil }
        let origin = Self.origin(imageSize: CGSize(width: drawn.width, height: drawn.height), in: extent, position: style.position)
        let image = CIImage(cgImage: drawn).transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        lock.withLock { cached = (caption.id, extent, image) }
        return image
    }

    /// Where the caption image's bottom-left corner goes (Core Image's origin is the bottom left).
    static func origin(imageSize: CGSize, in extent: CGRect, position: CaptionStyle.Position) -> CGPoint {
        let margin = extent.height * CaptionStyle.edgeMargin
        let x = extent.minX + (extent.width - imageSize.width) / 2
        let y = position == .bottom ? extent.minY + margin : extent.maxY - margin - imageSize.height
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// The font size for a picture: a share of its shorter side, so portrait and landscape videos get
    /// captions of the same size relative to the picture.
    static func fontSize(pictureSize: CGSize, style: CaptionStyle) -> CGFloat {
        max(12, min(pictureSize.width, pictureSize.height) * style.size.scale)
    }

    /// The caption drawn on a transparent background: centred lines, each on its own dark box or
    /// outlined. Text too wide for the picture is made smaller until it fits.
    static func image(for text: String, pictureSize: CGSize, style: CaptionStyle) -> CGImage? {
        let lines = WordsToCaptions.lines(text)
        guard !lines.isEmpty else { return nil }
        var size = fontSize(pictureSize: pictureSize, style: style)
        let maxWidth = pictureSize.width * CaptionStyle.maxWidthShare

        func layout(_ size: CGFloat) -> (lines: [CTLine], widths: [CGFloat], ascent: CGFloat, descent: CGFloat) {
            let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
            let made = lines.map { line in
                CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
                ]))
            }
            let widths = made.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
            return (made, widths, CTFontGetAscent(font), CTFontGetDescent(font))
        }

        var laid = layout(size)
        let padding = { (size: CGFloat) in (horizontal: size * 0.45, vertical: size * 0.18) }
        // The system font is drawn wider at small sizes (optical sizing), so one shrink may not be enough.
        for _ in 0..<6 {
            guard let widest = laid.widths.max() else { break }
            let needed = ceil(widest + 2 * padding(size).horizontal)
            guard needed > maxWidth else { break }
            size *= maxWidth / needed * 0.98
            laid = layout(size)
        }
        let pad = padding(size)
        let lineHeight = ceil(laid.ascent + laid.descent + 2 * pad.vertical)
        let width = Int(ceil((laid.widths.max() ?? 0) + 2 * pad.horizontal))
        let height = Int(lineHeight) * laid.lines.count
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        for (index, line) in laid.lines.enumerated() {
            // Line 0 is the top line; Core Graphics counts up from the bottom.
            let rowBottom = CGFloat(laid.lines.count - 1 - index) * lineHeight
            let lineWidth = laid.widths[index]
            let x = (CGFloat(width) - lineWidth) / 2
            let baseline = rowBottom + pad.vertical + laid.descent
            switch style.look {
            case .boxed:
                let box = CGRect(x: x - pad.horizontal, y: rowBottom, width: lineWidth + 2 * pad.horizontal, height: lineHeight)
                context.setFillColor(CGColor(gray: 0, alpha: 0.75))
                context.addPath(CGPath(roundedRect: box, cornerWidth: size * 0.2, cornerHeight: size * 0.2, transform: nil))
                context.fillPath()
            case .outlined:
                context.setLineJoin(.round)
                context.setLineWidth(size * 0.16)
                context.setStrokeColor(CGColor(gray: 0, alpha: 1))
                context.setTextDrawingMode(.stroke)
                context.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line, context)
                context.setTextDrawingMode(.fill)
            }
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }
}
