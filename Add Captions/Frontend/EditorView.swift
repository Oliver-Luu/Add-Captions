import AVFoundation
import AVKit
import SwiftUI

/// The video with its captions shown as they will look, beside a list of every caption to fix up, and
/// the buttons to change the style and save.
struct EditorView: View {
    @Environment(CaptionSession.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var player = AVPlayer()
    @State private var currentTime = 0.0
    @State private var isPlaying = false
    /// The picture's size as it is shown (after any rotation), once loaded.
    @State private var videoSize: CGSize?
    @State private var timeObserver: Any?

    var body: some View {
        Group {
            if sizeClass == .compact {
                VStack(spacing: 0) {
                    preview.frame(maxHeight: 280)
                    Divider()
                    CaptionList(currentTime: currentTime, isPlaying: isPlaying, seek: seek)
                }
            } else {
                HStack(spacing: 0) {
                    preview.padding(Metrics.regular)
                    Divider()
                    CaptionList(currentTime: currentTime, isPlaying: isPlaying, seek: seek)
                        .frame(width: Metrics.captionListWidth)
                }
            }
        }
        .navigationTitle(session.title)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if let exporting = session.exporting { ExportProgressBar(kind: exporting) }
        }
        .sheet(isPresented: Binding(get: { session.exportedFile != nil }, set: { if !$0 { session.discardExport() } })) {
            if let file = session.exportedFile { ExportReadyView(file: file) }
        }
        .alert("Couldn't save", isPresented: Binding(get: { session.exportError != nil }, set: { if !$0 { session.exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.exportError ?? "")
        }
        .task(id: session.videoURL) { await load() }
        .onDisappear {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
            player.pause()
        }
    }

    private var preview: some View {
        VideoPlayer(player: player)
            .overlay {
                GeometryReader { geometry in
                    if let videoSize, let caption = WordsToCaptions.caption(at: currentTime, in: session.captions) {
                        CaptionPreview(text: caption.text, style: session.style,
                                       pictureRect: Self.fit(videoSize, in: geometry.size))
                    }
                }
                .allowsHitTesting(false)
            }
            .background(.black)
            .clipShape(.rect(cornerRadius: sizeClass == .compact ? 0 : Metrics.cornerRadius))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("New Video", systemImage: "chevron.backward") { session.startOver() }
                .help("Close this video and caption another")
        }
        ToolbarItem {
            StyleMenu()
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(CaptionSession.Export.allCases) { kind in
                    Button { player.pause(); session.export(kind) } label: {
                        Label { Text(kind.title); Text(kind.detail) } icon: { Image(systemName: kind.systemImage) }
                    }
                }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(session.exporting != nil)
            .help("Save the captioned video or a caption file")
        }
    }

    // MARK: Playback

    private func load() async {
        guard let url = session.videoURL else { return }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [player] time in
            MainActor.assumeIsolated {
                currentTime = time.seconds
                isPlaying = player.rate != 0
            }
        }
        if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let rotated = CGRect(origin: .zero, size: size).applying(transform)
            videoSize = CGSize(width: abs(rotated.width), height: abs(rotated.height))
        }
    }

    private func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    /// Where a picture of `size` sits when fitted (letterboxed) into `container`.
    static func fit(_ size: CGSize, in container: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / size.width, container.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
}

/// A caption drawn by the same code that burns captions into the video, at the size it will have
/// there, so what you see is what you get.
struct CaptionPreview: View {
    var text: String
    var style: CaptionStyle
    /// The picture's frame within the player, in points.
    var pictureRect: CGRect

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let pixels = CGSize(width: pictureRect.width * displayScale, height: pictureRect.height * displayScale)
        if let image = CaptionRenderer.image(for: text, pictureSize: pixels, style: style) {
            let size = CGSize(width: CGFloat(image.width) / displayScale, height: CGFloat(image.height) / displayScale)
            let margin = pictureRect.height * CaptionStyle.edgeMargin
            Image(decorative: image, scale: displayScale)
                .position(
                    x: pictureRect.midX,
                    y: style.position == .bottom
                        ? pictureRect.maxY - margin - size.height / 2
                        : pictureRect.minY + margin + size.height / 2
                )
        }
    }
}

/// Size, position and look of the burned-in captions.
struct StyleMenu: View {
    @Environment(CaptionSession.self) private var session

    var body: some View {
        @Bindable var session = session
        Menu {
            Picker("Size", selection: $session.style.size) {
                ForEach(CaptionStyle.Size.allCases) { Text($0.label).tag($0) }
            }
            Picker("Position", selection: $session.style.position) {
                ForEach(CaptionStyle.Position.allCases) { Text($0.label).tag($0) }
            }
            Picker("Look", selection: $session.style.look) {
                ForEach(CaptionStyle.Look.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            Label("Caption Style", systemImage: "textformat.size")
        }
        .help("How burned-in captions look")
    }
}

/// Every caption, in order, each with its time (click to jump there) and its text to edit.
struct CaptionList: View {
    var currentTime: Double
    var isPlaying: Bool
    var seek: (Double) -> Void

    @Environment(CaptionSession.self) private var session
    @FocusState private var focused: Caption.ID?

    var body: some View {
        @Bindable var session = session
        let current = WordsToCaptions.caption(at: currentTime, in: session.captions)?.id
        ScrollViewReader { proxy in
            List {
                ForEach($session.captions) { $caption in
                    CaptionRow(caption: $caption, isCurrent: caption.id == current, currentTime: currentTime, seek: seek) {
                        session.delete(caption.id)
                    }
                    .focused($focused, equals: caption.id)
                    .id(caption.id)
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: current) { _, id in
                // Follow the video while it plays, but never move the list under someone typing.
                guard isPlaying, focused == nil, let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("\(session.captions.count) captions")
                    .font(.headline)
                Spacer()
                Button("Add Caption Here", systemImage: "plus") {
                    focused = session.addCaption(at: currentTime).id
                }
                .labelStyle(.iconOnly)
                .help("Add a caption at the playhead")
            }
            .padding(.horizontal, Metrics.regular)
            .padding(.vertical, Metrics.small)
            .background(.bar)
        }
    }
}

struct CaptionRow: View {
    @Binding var caption: Caption
    var isCurrent: Bool
    var currentTime: Double
    var seek: (Double) -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.medium) {
            Button { seek(caption.start) } label: {
                Text(formatTime(caption.start, precise: true))
                    .monospacedDigit()
                    .font(.callout)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help("Jump to this caption")
            TextField("Caption", text: $caption.text, axis: .vertical)
                .textFieldStyle(.plain)
                .fontWeight(isCurrent ? .semibold : .regular)
            Menu {
                Button("Start Caption at Playhead") { caption.start = min(currentTime, caption.end - 0.1) }
                Button("End Caption at Playhead") { caption.end = max(currentTime, caption.start + 0.1) }
                Divider()
                Button("Delete Caption", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .accessibilityLabel("Caption options")
        }
        .padding(.vertical, Metrics.tight)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

/// Shown along the bottom while a file is being made.
struct ExportProgressBar: View {
    var kind: CaptionSession.Export
    @Environment(CaptionSession.self) private var session

    var body: some View {
        HStack(spacing: Metrics.medium) {
            Text("Saving \(kind.title.lowercased())…")
                .font(.callout)
            ProgressView(value: session.exportProgress)
            Text("\(Int(session.exportProgress * 100))%")
                .monospacedDigit()
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Cancel") { session.cancelExport() }
        }
        .padding(Metrics.medium)
        .background(.bar)
    }
}

/// The finished file: choose where to keep it, or share it (on iPhone and iPad, "Save Video" puts it
/// in Photos).
struct ExportReadyView: View {
    var file: URL
    @Environment(CaptionSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var isMoving = false

    var body: some View {
        VStack(spacing: Metrics.regular) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("“\(file.lastPathComponent)” is ready")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            HStack(spacing: Metrics.medium) {
                Button("Save to…", systemImage: "folder") { isMoving = true }
                    .buttonStyle(.borderedProminent)
                ShareLink(item: file)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            Button("Close", role: .cancel) { dismiss() }
                .buttonStyle(.borderless)
        }
        .padding(Metrics.extraLarge)
        .frame(minWidth: 360)
        .fileMover(isPresented: $isMoving, file: file) { result in
            switch result {
            case .success: dismiss()
            case .failure(let error): session.exportError = error.localizedDescription
            }
        }
    }
}
