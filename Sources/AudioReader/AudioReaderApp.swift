import SwiftUI
import Foundation

@main
struct AudioReaderApp: App {
    @State private var state = AppState()

    init() {
#if os(macOS)
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
#endif
    }

    var body: some Scene {
#if os(macOS)
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
                Button("Skip back") { state.skipPlayback(seconds: -state.settings.skipSeconds) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Skip forward") { state.skipPlayback(seconds: state.settings.skipSeconds) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Toggle("Loop sentence", isOn: Binding(
                    get: { state.loopSentence },
                    set: { state.setSentenceLoop($0) }
                ))
                    .keyboardShortcut("l", modifiers: [.command])
                Toggle("Deep Reading", isOn: Binding(
                    get: { state.settings.deepReadingMode },
                    set: { state.setDeepReadingMode($0) }
                ))
                    .keyboardShortcut("d", modifiers: [.command])
                Button("Continue with next sentence") { state.continueDeepReading() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!state.canContinueDeepReading)
            }
            CommandMenu("Book") {
                Button("Contents") { state.presentBookContents(tab: .contents) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(state.selectedBook == nil)
                Button("Find in Book…") { state.presentBookContents(tab: .search) }
                    .keyboardShortcut("f", modifiers: [.command])
                    .disabled(state.selectedBook == nil)
                Button(state.isCurrentLocationBookmarked ? "Remove Bookmark" : "Bookmark") {
                    state.toggleBookmark()
                }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(state.selectedChapter == nil)
            }
            CommandMenu("Study") {
                Toggle("Study overlay", isOn: Binding(
                    get: { state.settings.showStudyOverlay },
                    set: {
                        state.settings.showStudyOverlay = $0
                        state.persistSettings()
                    }
                ))
                .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Mark known") { state.markSelectedWordKnown(true) }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(state.selectedWord == nil)
                Button("Chapter words") {
                    state.presentChapterStudyList()
                }
                    .disabled(state.transcript == nil)
                Button("Shadow this sentence") {
                    state.presentShadowing()
                }
                    .disabled(state.transcript == nil)
                Button("Chapter quiz") {
                    state.presentChapterQuiz()
                }
                    .disabled(state.transcript == nil)
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
#else
        WindowGroup {
            IPadRootView(state: state)
                .preferredColorScheme(AppAppearance(rawValue: state.settings.appearance)?.colorScheme)
        }
#endif
    }
}
