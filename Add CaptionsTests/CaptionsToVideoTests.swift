import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Add_Captions

@Suite("Captions to video")
struct CaptionsToVideoTests {
    @Test func textSamplesStartWithTheirLength() {
        #expect(CaptionsToVideo.textSample("") == Data([0, 0]))
        #expect(CaptionsToVideo.textSample("Hi") == Data([0, 2, 0x48, 0x69]))
        // Length is in UTF-8 bytes, not characters.
        #expect(CaptionsToVideo.textSample("é").prefix(2) == Data([0, 2]))
    }

    @Test func subtitleSamplesFillEveryGap() {
        let samples = CaptionsToVideo.subtitleSamples([
            Caption(start: 1, end: 2, text: "a"),
            Caption(start: 1.5, end: 3, text: "b"),  // overlaps "a": starts when "a" ends
            Caption(start: 4, end: 9, text: "c"),  // runs past the end of the video
        ], duration: 5)
        #expect(samples.map(\.text) == ["", "a", "b", "", "c"])
        #expect(samples.map(\.start) == [0, 1, 2, 3, 4])
        #expect(samples.map(\.end) == [1, 2, 3, 4, 5])
    }

    @Test func fileTypeFollowsTheInput() {
        #expect(CaptionsToVideo.fileType(for: URL(filePath: "/a/b.MOV")) == .mov)
        #expect(CaptionsToVideo.fileType(for: URL(filePath: "/a/b.mp4")) == .mp4)
        #expect(CaptionsToVideo.fileType(for: URL(filePath: "/a/b.m4v")) == .mp4)
    }

    @Test func captionsSitNearTheChosenEdge() {
        let extent = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let size = CGSize(width: 600, height: 100)
        let bottom = CaptionRenderer.origin(imageSize: size, in: extent, position: .bottom)
        let top = CaptionRenderer.origin(imageSize: size, in: extent, position: .top)
        let margin = 1080 * CaptionStyle.edgeMargin
        #expect(bottom.x == 660)
        #expect(abs(bottom.y - margin) <= 1)
        // The top of the caption is the same distance from the top edge.
        #expect(abs(1080 - (top.y + 100) - margin) <= 1)
    }

    @Test func captionImagesFitThePicture() throws {
        let long = "Supercalifragilisticexpialidocious antidisestablishmentarianism pneumonoultramicroscopic"
        for picture in [CGSize(width: 1920, height: 1080), CGSize(width: 360, height: 640)] {
            for size in CaptionStyle.Size.allCases {
                let image = try #require(CaptionRenderer.image(for: long, pictureSize: picture, style: CaptionStyle(size: size)))
                #expect(CGFloat(image.width) <= picture.width * CaptionStyle.maxWidthShare + 1)
            }
        }
        #expect(CaptionRenderer.image(for: " ", pictureSize: CGSize(width: 100, height: 100), style: CaptionStyle()) == nil)
    }

    @Test func biggerStylesMakeBiggerText() {
        let picture = CGSize(width: 1920, height: 1080)
        let sizes = CaptionStyle.Size.allCases.map { CaptionRenderer.fontSize(pictureSize: picture, style: CaptionStyle(size: $0)) }
        #expect(sizes == sizes.sorted())
        // Portrait and landscape of the same resolution get the same size.
        #expect(CaptionRenderer.fontSize(pictureSize: picture, style: CaptionStyle())
            == CaptionRenderer.fontSize(pictureSize: CGSize(width: 1080, height: 1920), style: CaptionStyle()))
    }

    // MARK: Real files

    @Test func burnsCaptionsIntoThePicture() async throws {
        let video = try await TestMedia.makeGreyVideo(seconds: 4)
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
        defer { [video, output].forEach { try? FileManager.default.removeItem(at: $0) } }
        let captions = [Caption(start: 1, end: 2.5, text: "Hello captions")]
        try await CaptionsToVideo.burnIn(captions, into: video, style: CaptionStyle(), to: output) { _ in }

        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 4) < 0.2)
        let during = try await TestMedia.frame(of: output, at: 1.8)
        let before = try await TestMedia.frame(of: output, at: 0.5)
        let bottom = (during.height * 2 / 3)..<during.height
        let topRows = 0..<(during.height / 3)
        // The dark box and white text are in the bottom third while the caption shows, and only then.
        let shown = TestMedia.darkAndLight(during, rows: bottom)
        #expect(shown.dark > 1000)
        #expect(shown.light > 200)
        #expect(TestMedia.darkAndLight(during, rows: topRows).dark == 0)
        #expect(TestMedia.darkAndLight(before, rows: bottom).dark == 0)
    }

    @Test func burnedCaptionsFollowARotatedVideo() async throws {
        // Stored 640×360 but shown 360×640, like a portrait phone video.
        let video = try await TestMedia.makeGreyVideo(seconds: 2, rotated: true)
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
        defer { [video, output].forEach { try? FileManager.default.removeItem(at: $0) } }
        try await CaptionsToVideo.burnIn([Caption(start: 0, end: 2, text: "Portrait")], into: video,
                                         style: CaptionStyle(), to: output) { _ in }
        let frame = try await TestMedia.frame(of: output, at: 1)
        #expect(frame.width == 360)
        #expect(frame.height == 640)
        #expect(TestMedia.darkAndLight(frame, rows: (frame.height * 3 / 4)..<frame.height).dark > 300)
        #expect(TestMedia.darkAndLight(frame, rows: 0..<(frame.height / 2)).dark == 0)
    }

    @Test(arguments: ["mov", "mp4"])
    func addsAnEnglishSubtitleTrack(fileExtension: String) async throws {
        let video = try await TestMedia.makeGreyVideo(seconds: 4)
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + fileExtension)
        defer { [video, output].forEach { try? FileManager.default.removeItem(at: $0) } }
        let captions = [Caption(start: 0.5, end: 1.5, text: "First caption"), Caption(start: 2, end: 3, text: "Second one")]
        try await CaptionsToVideo.addSubtitleTrack(captions, to: video, output: output) { _ in }

        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let track = try #require(try await asset.loadTracks(withMediaType: .subtitle).first)
        #expect(try await track.load(.languageCode) == "eng")
        // Players list it as a caption choice.
        let group = try await asset.loadMediaSelectionGroup(for: .legible)
        #expect(group?.options.isEmpty == false)

        // Read the text back out of the samples.
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(trackOutput)
        #expect(reader.startReading())
        var texts: [String] = []
        while let sample = trackOutput.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            guard data.count >= 2 else { continue }
            let length = Int(data[0]) << 8 | Int(data[1])
            if length > 0 { texts.append(String(decoding: data[2..<(2 + length)], as: UTF8.self)) }
        }
        #expect(texts == ["First caption", "Second one"])
    }

    /// Speech in, captions out: the whole pipeline on a spoken test video.
    @Test func captionsASpokenVideo() async throws {
        let video = try await TestMedia.makeSpokenVideo(
            "Welcome to the captioning test. Today we are checking that every spoken word appears on screen."
        )
        defer { try? FileManager.default.removeItem(at: video) }
        let words = try await AudioToTranscription.transcribe(video) { _ in }
        let captions = WordsToCaptions.captions(from: words)
        let text = captions.map(\.text).joined(separator: " ").lowercased()
        for expected in ["welcome", "captioning", "test", "today", "spoken", "screen"] {
            #expect(text.contains(expected), "missing \(expected) in: \(text)")
        }
        // Times are in order and inside the video.
        let duration = try await AVURLAsset(url: video).load(.duration).seconds
        for (word, next) in zip(words, words.dropFirst()) { #expect(word.start <= next.start) }
        #expect(words.allSatisfy { $0.start >= 0 && $0.end <= duration + 0.5 && $0.end >= $0.start })
        #expect(captions.count >= 2)
    }
}
