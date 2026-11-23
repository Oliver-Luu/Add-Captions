import SwiftUI

@main struct MyApp: App {
    @State private var session = CaptionSession()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .environment(session)
            .tint(.brand)
            #if DEBUG
            // For checking the app by hand: `-openVideo <path>` opens a video at launch (Debug builds only).
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "-openVideo"), index + 1 < arguments.count, session.phase == .idle {
                    session.open(URL(filePath: arguments[index + 1]))
                }
            }
            #endif
        }
        .defaultSize(width: 1100, height: 720)
        .commands { CaptionCommands(session: session) }
    }
}

/// The File menu: open a video, and save in each format (the same choices as the Save button).
struct CaptionCommands: Commands {
    var session: CaptionSession

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Video…") {
                session.startOver()
                session.isChoosingVideo = true
            }
            .keyboardShortcut("o")
            .disabled(session.phase == .transcribing)
        }
        CommandGroup(replacing: .saveItem) {
            ForEach(CaptionSession.Export.allCases) { kind in
                Button("Save \(kind.title)…") { session.export(kind) }
                    .keyboardShortcut(Self.shortcut(for: kind))
                    .disabled(!session.canExport)
            }
        }
    }

    /// ⌘S burns captions in (the choice that works everywhere); ⇧⌘S adds a subtitle track.
    static func shortcut(for kind: CaptionSession.Export) -> KeyboardShortcut? {
        switch kind {
        case .burnedIn: KeyboardShortcut("s")
        case .subtitleTrack: KeyboardShortcut("s", modifiers: [.command, .shift])
        case .srt, .webVTT: nil
        }
    }
}
