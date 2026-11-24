import SwiftUI
import UniformTypeIdentifiers

/// Shows the screen for where the session is: choosing a video, transcribing it, or editing captions.
struct ContentView: View {
    @Environment(CaptionSession.self) private var session
    @State private var isTargeted = false

    var body: some View {
        @Bindable var session = session
        Group {
            switch session.phase {
            case .idle:
                ImportView(isTargeted: isTargeted) { session.isChoosingVideo = true }
            case .transcribing:
                TranscribingView()
            case .editing:
                EditorView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't caption this video", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Choose Another Video") { session.startOver(); session.isChoosingVideo = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .windowCanvas()
        .fileImporter(isPresented: $session.isChoosingVideo, allowedContentTypes: Self.videoTypes) { result in
            if case .success(let url) = result { session.open(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: Self.isVideo) else { return false }
            session.open(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    nonisolated static let videoTypes: [UTType] = [.movie, .video]

    /// True for files the system knows as video (.mp4, .mov, .m4v…).
    nonisolated static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return videoTypes.contains { type.conforms(to: $0) }
    }
}

/// The first screen: drop a video, or choose one.
struct ImportView: View {
    var isTargeted: Bool
    var onChoose: () -> Void

    var body: some View {
        VStack(spacing: Metrics.large) {
            LogoMark()
                .fill(.tint, style: FillStyle(eoFill: true))
                .frame(width: 70, height: 70 / LogoMark.aspectRatio)
                .accessibilityHidden(true)
            Text("Add English captions to a video")
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
            VStack(spacing: Metrics.regular) {
                Text(isTargeted ? "Let go to caption this video" : "Drop a video here")
                    .font(.title3)
                    .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Button("Choose Video…", systemImage: "plus", action: onChoose)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
            .padding(Metrics.extraLarge)
            .frame(maxWidth: 560)
            .background(isTargeted ? AnyShapeStyle(.tint.opacity(0.1)) : AnyShapeStyle(Color.panel), in: .rect(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                  style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [6]))
            }
            Label("Speech is recognized on this device. Your video never leaves it.", systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Metrics.large)
    }
}

/// While the video is being listened to.
struct TranscribingView: View {
    @Environment(CaptionSession.self) private var session

    var body: some View {
        VStack(spacing: Metrics.regular) {
            Text("Listening to “\(session.title)”")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            ProgressView(value: session.progress)
                .frame(maxWidth: 360)
            Text(session.progress < 0.01
                 ? "Getting ready. The first time, the English speech model may need to download."
                 : "\(Int(session.progress * 100))%")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .monospacedDigit()
            Button("Stop", role: .cancel) { session.startOver() }
                .buttonStyle(.bordered)
        }
        .padding(Metrics.large)
    }
}
