import Foundation
import Testing
@testable import Add_Captions

@MainActor
@Suite("Caption session")
struct CaptionSessionTests {
    /// Waits until `condition` holds, for at most `seconds`.
    private func wait(_ seconds: Double = 5, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private let video = URL(filePath: "/tmp/My Talk.mov")

    @Test func transcribingLeadsToEditing() async {
        let session = CaptionSession { _, progress in
            progress(0.5)
            return [TimedWord(start: 0, end: 0.4, text: "Hello."), TimedWord(start: 0.5, end: 0.9, text: "Bye.")]
        }
        session.open(video)
        #expect(session.phase == .transcribing)
        #expect(session.title == "My Talk")
        await wait { session.phase == .editing }
        #expect(session.phase == .editing)
        #expect(session.captions.map(\.text) == ["Hello.", "Bye."])
    }

    @Test func noSpeechIsAFailure() async {
        let session = CaptionSession { _, _ in [] }
        session.open(video)
        await wait { session.phase != .transcribing }
        #expect(session.phase == .failed(CaptionSession.noSpeechMessage))
    }

    @Test func errorsAreShown() async {
        let session = CaptionSession { _, _ in throw AudioToTranscription.Failure.noAudio }
        session.open(video)
        await wait { session.phase != .transcribing }
        #expect(session.phase == .failed(AudioToTranscription.Failure.noAudio.localizedDescription))
    }

    @Test func stoppingGoesBackToTheStart() async {
        let session = CaptionSession { _, _ in
            try await Task.sleep(for: .seconds(30))
            return [TimedWord(start: 0, end: 1, text: "late")]
        }
        session.open(video)
        session.startOver()
        #expect(session.phase == .idle)
        #expect(session.videoURL == nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(session.phase == .idle)
        #expect(session.captions.isEmpty)
    }

    @Test func addingAndDeletingCaptions() {
        let session = CaptionSession { _, _ in [] }
        session.captions = [Caption(start: 0, end: 1, text: "a"), Caption(start: 3, end: 4, text: "c")]
        let added = session.addCaption(at: 2)
        #expect(session.captions.map(\.start) == [0, 2, 3])
        // Lasts 2 seconds unless the next caption comes sooner.
        #expect(added.end == 3)
        #expect(session.addCaption(at: 10).end == 12)
        session.delete(added.id)
        #expect(session.captions.map(\.start) == [0, 3, 10])
    }

    @Test func exportsACaptionFileWithAReadableName() async throws {
        let session = CaptionSession { _, _ in [TimedWord(start: 1, end: 1.5, text: "Hello.")] }
        session.open(video)
        await wait { session.phase == .editing }
        session.captions.append(Caption(start: 5, end: 6, text: "   "))  // empty captions are left out
        session.export(.srt)
        await wait { session.exportedFile != nil || session.exportError != nil }
        let file = try #require(session.exportedFile)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(file.lastPathComponent == "My Talk.srt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "1\n00:00:01,000 --> 00:00:02,000\nHello.\n")
        #expect(session.exporting == nil)
        #expect(session.canExport)
        // Closing without saving deletes the file.
        session.discardExport()
        #expect(session.exportedFile == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func videoExportsKeepTheVideoType() {
        let mov = CaptionSession.outputURL(for: .burnedIn, video: URL(filePath: "/a/clip.mov"), title: "clip")
        let mp4 = CaptionSession.outputURL(for: .subtitleTrack, video: URL(filePath: "/a/clip.m4v"), title: "clip")
        #expect(mov.lastPathComponent == "clip (captioned).mov")
        #expect(mp4.lastPathComponent == "clip (captioned).mp4")
        #expect(CaptionSession.outputURL(for: .webVTT, video: mov, title: "").lastPathComponent == "Video.vtt")
    }

    @Test func onlyVideosAreAccepted() {
        #expect(ContentView.isVideo(URL(filePath: "/a/b.mp4")))
        #expect(ContentView.isVideo(URL(filePath: "/a/b.MOV")))
        #expect(!ContentView.isVideo(URL(filePath: "/a/b.mp3")))
        #expect(!ContentView.isVideo(URL(filePath: "/a/b.pdf")))
    }

    @Test func timesReadWell() {
        #expect(formatTime(65) == "1:05")
        #expect(formatTime(3725) == "1:02:05")
        #expect(formatTime(1.25, precise: true) == "0:01.2")
        #expect(formatTime(.nan) == "0:00")
    }

    @Test func fittingAPictureLetterboxes() {
        let rect = EditorView.fit(CGSize(width: 1920, height: 1080), in: CGSize(width: 400, height: 400))
        #expect(rect == CGRect(x: 0, y: 87.5, width: 400, height: 225))
    }
}
