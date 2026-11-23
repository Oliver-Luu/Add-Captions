import AVFoundation
import CoreGraphics
import Foundation
import Testing

/// Videos generated for tests.
enum TestMedia {
    /// Writes a silent video of a flat grey picture, `width`×`height`, at 10 frames per second.
    /// `rotated` stores it sideways with a 90° display rotation, as phones record portrait video.
    static func makeGreyVideo(seconds: Double, width: Int = 640, height: Int = 360, rotated: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
        let framesPerSecond = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0..<Int(seconds * Double(framesPerSecond)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            let buffer = try #require(created)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(framesPerSecond)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()
        return url
    }

    /// A grey video with `text` spoken by the system voice over it, as long as the speech.
    static func makeSpokenVideo(_ text: String) async throws -> URL {
        let speech = try await makeSpeech(text)
        defer { try? FileManager.default.removeItem(at: speech) }
        let audio = AVURLAsset(url: speech)
        let duration = try await audio.load(.duration)
        let video = try await makeGreyVideo(seconds: ceil(duration.seconds) + 1)
        defer { try? FileManager.default.removeItem(at: video) }

        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: duration)
        // Kept in a variable: a track can't be inserted once its asset has been released.
        let videoAsset = AVURLAsset(url: video)
        let videoTrack = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await audio.loadTracks(withMediaType: .audio).first)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: audioTrack, at: .zero)
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await export.export(to: output, as: .mov)
        return output
    }

    /// Writes `text` spoken by the system voice to an audio file.
    static func makeSpeech(_ text: String) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        let writer = SpeechWriter(url: url)
        let synthesizer = AVSpeechSynthesizer()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            synthesizer.write(AVSpeechUtterance(string: text)) { buffer in
                if let result = writer.take(buffer) { continuation.resume(with: result) }
            }
        }
        writer.close()
        return url
    }

    /// The picture at `seconds`, as shown (rotation applied), as RGBA bytes.
    static func frame(of url: URL, at seconds: Double) async throws -> (pixels: [UInt8], width: Int, height: Int) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }

    /// How many pixels in rows `rows` (0 is the top) are near black and how many near white.
    static func darkAndLight(_ frame: (pixels: [UInt8], width: Int, height: Int), rows: Range<Int>) -> (dark: Int, light: Int) {
        var dark = 0, light = 0
        for row in rows {
            for column in 0..<frame.width {
                let index = (row * frame.width + column) * 4
                let brightness = (Int(frame.pixels[index]) + Int(frame.pixels[index + 1]) + Int(frame.pixels[index + 2])) / 3
                if brightness < 90 { dark += 1 }
                if brightness > 200 { light += 1 }
            }
        }
        return (dark, light)
    }

    /// Collects the synthesizer's audio into a file. The last buffer it sends is empty.
    private final class SpeechWriter: @unchecked Sendable {
        private let url: URL
        private var file: AVAudioFile?
        private var isFinished = false

        init(url: URL) { self.url = url }

        /// Nil while more audio is coming; otherwise how the speech ended (reported once).
        func take(_ buffer: AVAudioBuffer) -> Result<Void, any Error>? {
            guard !isFinished, let audio = buffer as? AVAudioPCMBuffer else { return nil }
            if audio.frameLength == 0 {
                isFinished = true
                return .success(())
            }
            do {
                if file == nil {
                    // AAC in .m4a: AVFoundation reads it everywhere, including inside the app sandbox.
                    file = try AVAudioFile(
                        forWriting: url,
                        settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audio.format.sampleRate,
                                   AVNumberOfChannelsKey: audio.format.channelCount],
                        commonFormat: audio.format.commonFormat, interleaved: audio.format.isInterleaved
                    )
                }
                try file?.write(from: audio)
                return nil
            } catch {
                isFinished = true
                return .failure(error)
            }
        }

        func close() { file = nil }
    }
}
