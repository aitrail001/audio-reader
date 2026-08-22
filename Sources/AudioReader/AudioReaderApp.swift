import SwiftUI
import Foundation

@main
struct AudioReaderApp: App {
    @State private var state = AppState()

    init() {
        let args = CommandLine.arguments
        if args.contains("--scan") {
            Cli.scan()
            Foundation.exit(0)
        }
        if let idx = args.firstIndex(of: "--transcribe"), args.indices.contains(idx + 1) {
            let audio = args[idx + 1]
            let ebook = args.indices.contains(idx + 2) ? args[idx + 2] : nil
            Cli.transcribe(audioPath: audio, ebookPath: ebook)
            Foundation.exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(state: state)
                .frame(minWidth: 980, minHeight: 640)
                .background(Palette.bg)
                .preferredColorScheme(AppAppearance(rawValue: state.settings.appearance)?.colorScheme)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandMenu("Playback") {
                Button(state.player.isPlaying ? "Pause" : "Play") {
                    state.togglePlay()
                }
                .keyboardShortcut(.space, modifiers: [])
                Button("Replay sentence") { state.replaySentence() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Previous sentence") { state.skipSentence(direction: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.option])
                Button("Next sentence") { state.skipSentence(direction: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.option])
                Button("Skip back") { state.player.skip(seconds: -state.settings.skipSeconds) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Skip forward") { state.player.skip(seconds: state.settings.skipSeconds) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Toggle("Loop sentence", isOn: $state.loopSentence)
                    .keyboardShortcut("l", modifiers: [.command])
            }
            CommandMenu("Library") {
                Button("Choose Books Folder…") { state.chooseLibrary() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Rescan Library") {
                    Task { await state.rescan() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Transcribe Chapter") { state.transcribeSelected() }
                    .keyboardShortcut("t", modifiers: [.command])
            }
        }
    }
}
