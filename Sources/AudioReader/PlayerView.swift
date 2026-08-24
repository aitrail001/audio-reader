import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ReaderScrollTarget: Equatable {
    var chapterID: String
    var segmentID: String

    func segmentID(for selectedChapterID: String?) -> String? {
        chapterID == selectedChapterID ? segmentID : nil
    }

    static func shouldAnimate(from previous: ReaderScrollTarget?, to next: ReaderScrollTarget) -> Bool {
        previous?.chapterID == next.chapterID
    }
}

struct PlayerView: View {
    @Bindable var state: AppState
    @State private var autoScroll = true
    @State private var lookupWidth: CGFloat = 0
    @State private var lookupDragStart: CGFloat?
    @State private var readerScrollTarget: ReaderScrollTarget?
#if os(iOS)
    @State private var showReaderToolbar = false
    @State private var showSpeedPicker = false
#endif

    var body: some View {
        VStack(spacing: 0) {
#if os(iOS)
            if showReaderToolbar {
                header
                Divider().overlay(Palette.line)
            }
#else
            header
            Divider().overlay(Palette.line)
#endif
            if state.isTranscribing {
                transcribeBanner
            }
            if let err = state.errorMessage ?? state.translationError ?? state.player.playbackError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
            }
            if let notice = state.vocabularyNotice {
                HStack(spacing: 8) {
                    Label(notice, systemImage: notice.contains("already") ? "bookmark.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Button {
                        state.vocabularyNotice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.goldSoft)
            }
            lyricPane
            controls
        }
        .background(Palette.bg)
#if os(iOS)
        .navigationTitle(readerNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showReaderToolbar.toggle()
                } label: {
                    Label(
                        showReaderToolbar ? "Hide Reader Controls" : "Show Reader Controls",
                        systemImage: showReaderToolbar ? "chevron.up" : "slider.horizontal.3"
                    )
                }
                .accessibilityLabel(showReaderToolbar ? "Hide reader controls" : "Show reader controls")
            }
        }
#endif
        .onChange(of: state.player.currentTime) { _, _ in
            state.tickLoop()
        }
        .onChange(of: state.currentSegment?.id) { _, _ in
            state.ensureAutoTranslation()
        }
    }

    private var header: some View {
#if os(iOS)
        iPadHeader
#else
        desktopHeader
#endif
    }

    private var desktopHeader: some View {
        HStack(spacing: 14) {
            if let path = state.selectedBook?.coverPath, let img = CoverImageCache.shared.image(for: path) {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.selectedBook?.title ?? "No book")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(Palette.ink)
                Text(state.selectedChapter?.title ?? "Choose a chapter")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.dim)
            }
            Spacer()
            Picker("Text", selection: $state.textSource) {
                ForEach(TextSource.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .fixedSize(horizontal: true, vertical: false)
            .onChange(of: state.textSource) { _, _ in state.persistSettings() }

            Picker("Provider", selection: $state.settings.llmProvider) {
                ForEach(LLMProvider.allCases) { provider in
                    Text(provider.menuLabel).tag(provider.rawValue)
                }
            }
            .frame(maxWidth: 130)
            .onChange(of: state.settings.llmProvider) { _, provider in
                state.persistSettings()
                if provider == LLMProvider.qwenCloud.rawValue {
                    Task { await state.refreshQwenModels() }
                }
            }

            if state.llmProvider == .grok {
                Picker("Model", selection: $state.settings.grokModel) {
                    ForEach(GrokModel.allCases) { model in
                        Text(model.rawValue).tag(model.rawValue)
                    }
                }
                .frame(maxWidth: 140)
                .onChange(of: state.settings.grokModel) { _, _ in state.persistSettings() }

                if GrokModel(rawValue: state.settings.grokModel)?.supportsEffort == true {
                    Picker("Effort", selection: $state.settings.grokEffort) {
                        ForEach(GrokEffort.allCases) { effort in
                            Text(effort.rawValue).tag(effort.rawValue)
                        }
                    }
                    .frame(maxWidth: 110)
                    .onChange(of: state.settings.grokEffort) { _, _ in state.persistSettings() }
                }
            } else {
                Picker("Model", selection: $state.settings.qwenModel) {
                    ForEach(state.qwenTextModels) { model in
                        Text(model.id).tag(model.id)
                    }
                }
                .frame(maxWidth: 180)
                .onChange(of: state.settings.qwenModel) { _, _ in
                    state.persistSettings()
                    state.normalizeSelectedQwenEffort()
                }
                if state.qwenSupportsThinkingToggle {
                    Toggle("Thinking", isOn: $state.settings.qwenThinking)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: state.settings.qwenThinking) { _, _ in state.persistSettings() }
                }
                if !state.selectedQwenEfforts.isEmpty
                    && (!state.qwenSupportsThinkingToggle || state.settings.qwenThinking) {
                    Picker("Effort", selection: $state.settings.qwenEffort) {
                        ForEach(state.selectedQwenEfforts) { effort in
                            Text(effort.rawValue).tag(effort.rawValue)
                        }
                    }
                    .frame(maxWidth: 105)
                    .onChange(of: state.settings.qwenEffort) { _, _ in state.persistSettings() }
                }
            }

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.switch)
                .controlSize(.small)
                .foregroundStyle(Palette.dim)

            Toggle("Play on tap", isOn: $state.settings.playOnSelect)
                .toggleStyle(.switch)
                .controlSize(.small)
                .foregroundStyle(Palette.dim)
                .onChange(of: state.settings.playOnSelect) { _, _ in state.persistSettings() }
                .help("When on, clicking a sentence or word starts playback. When off, it only jumps to that spot.")

            Menu {
                readingAppearanceMenuContent
            } label: {
                Label("Reading", systemImage: "textformat")
            }
            .fixedSize(horizontal: true, vertical: false)

            Button {
                state.showChapterAssistant.toggle()
            } label: {
                Label("Chapter AI", systemImage: "sparkles")
            }
            .foregroundStyle(state.showChapterAssistant ? Palette.gold : Palette.ink)
            .disabled(state.selectedChapter == nil)

            Button {
                state.transcribeSelected(force: state.transcript != nil)
            } label: {
                Label(state.transcript == nil ? "Transcribe" : "Re-transcribe", systemImage: "waveform")
            }
            .disabled(state.selectedChapter == nil || state.isTranscribing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Palette.panel)
    }

#if os(iOS)
    private var readerNavigationTitle: String {
        [state.selectedBook?.title, state.selectedChapter?.title]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var iPadHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                iPadTextSourcePicker
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)
                Spacer(minLength: 0)
                iPadLLMMenu
                iPadReadingMenu
                Button {
                    state.showChapterAssistant.toggle()
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(state.showChapterAssistant ? Palette.gold : Palette.terracotta)
                .disabled(state.selectedChapter == nil)
                .accessibilityLabel("Chapter AI")
                .help("Chapter AI")

                Button {
                    state.transcribeSelected(force: state.transcript != nil)
                } label: {
                    Image(systemName: "waveform")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Palette.terracotta)
                .disabled(state.selectedChapter == nil || state.isTranscribing)
                .accessibilityLabel(state.transcript == nil ? "Transcribe" : "Re-transcribe")
                .help(state.transcript == nil ? "Transcribe chapter" : "Re-transcribe chapter")
            }
            VStack(alignment: .leading, spacing: 10) {
                iPadTextSourcePicker
                    .frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    iPadLLMMenu
                    iPadReadingMenu
                    Spacer(minLength: 0)
                    Button {
                        state.showChapterAssistant.toggle()
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(state.showChapterAssistant ? Palette.gold : Palette.terracotta)
                    .disabled(state.selectedChapter == nil)
                    .accessibilityLabel("Chapter AI")

                    Button {
                        state.transcribeSelected(force: state.transcript != nil)
                    } label: {
                        Image(systemName: "waveform")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Palette.terracotta)
                    .disabled(state.selectedChapter == nil || state.isTranscribing)
                    .accessibilityLabel(state.transcript == nil ? "Transcribe" : "Re-transcribe")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.panel)
    }

    private var iPadTextSourcePicker: some View {
        Picker("Text", selection: $state.textSource) {
            ForEach(TextSource.allCases) { source in
                Text(source.rawValue).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: state.textSource) { _, _ in state.persistSettings() }
    }

    private var iPadLLMMenu: some View {
        Menu {
            Picker("Provider", selection: $state.settings.llmProvider) {
                ForEach(LLMProvider.allCases) { provider in
                    Text(provider.menuLabel).tag(provider.rawValue)
                }
            }
            .onChange(of: state.settings.llmProvider) { _, provider in
                state.persistSettings()
                if provider == LLMProvider.qwenCloud.rawValue {
                    Task { await state.refreshQwenModels() }
                }
            }

            if state.llmProvider == .grok {
                Picker("Model", selection: $state.settings.grokModel) {
                    ForEach(GrokModel.allCases) { model in
                        Text(model.rawValue).tag(model.rawValue)
                    }
                }
                .onChange(of: state.settings.grokModel) { _, _ in state.persistSettings() }

                if GrokModel(rawValue: state.settings.grokModel)?.supportsEffort == true {
                    Picker("Effort", selection: $state.settings.grokEffort) {
                        ForEach(GrokEffort.allCases) { effort in
                            Text(effort.rawValue).tag(effort.rawValue)
                        }
                    }
                    .onChange(of: state.settings.grokEffort) { _, _ in state.persistSettings() }
                }
            } else {
                Picker("Model", selection: $state.settings.qwenModel) {
                    ForEach(state.qwenTextModels) { model in
                        Text(model.id).tag(model.id)
                    }
                }
                .onChange(of: state.settings.qwenModel) { _, _ in
                    state.persistSettings()
                    state.normalizeSelectedQwenEffort()
                }

                if state.qwenSupportsThinkingToggle {
                    Toggle("Thinking", isOn: $state.settings.qwenThinking)
                        .onChange(of: state.settings.qwenThinking) { _, _ in state.persistSettings() }
                }
                if !state.selectedQwenEfforts.isEmpty
                    && (!state.qwenSupportsThinkingToggle || state.settings.qwenThinking) {
                    Picker("Effort", selection: $state.settings.qwenEffort) {
                        ForEach(state.selectedQwenEfforts) { effort in
                            Text(effort.rawValue).tag(effort.rawValue)
                        }
                    }
                    .onChange(of: state.settings.qwenEffort) { _, _ in state.persistSettings() }
                }
            }
        } label: {
            Label(state.llmProvider.menuLabel, systemImage: "brain.head.profile")
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("AI settings")
    }

    private var iPadReadingMenu: some View {
        Menu {
            Toggle("Auto-scroll", isOn: $autoScroll)
            Toggle("Play on tap", isOn: $state.settings.playOnSelect)
                .onChange(of: state.settings.playOnSelect) { _, _ in state.persistSettings() }
            Divider()
            readingAppearanceMenuContent
        } label: {
            Label("Reading", systemImage: "textformat")
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Reading settings")
    }
#endif

    @ViewBuilder
    private var readingAppearanceMenuContent: some View {
        Menu("Typeface") {
            Picker("Typeface", selection: $state.settings.readerFont) {
                ForEach(ReaderFontChoice.allCases) { font in
                    Text(font.rawValue).tag(font.rawValue)
                }
            }
        }
        .onChange(of: state.settings.readerFont) { _, _ in state.persistSettings() }
        Toggle("Bold Text", isOn: $state.settings.readerBold)
            .onChange(of: state.settings.readerBold) { _, _ in state.persistSettings() }
        Divider()
        Button {
            state.settings.readerFontScale = max(0.75, (state.settings.readerFontScale * 10 - 1).rounded() / 10)
            state.persistSettings()
        } label: {
            Label("Smaller Text", systemImage: "textformat.size.smaller")
        }
        Button {
            state.settings.readerFontScale = min(1.6, (state.settings.readerFontScale * 10 + 1).rounded() / 10)
            state.persistSettings()
        } label: {
            Label("Larger Text", systemImage: "textformat.size.larger")
        }
        Button("Increase Line Spacing") {
            state.settings.readerLineSpacing = min(2, state.settings.readerLineSpacing + 0.1)
            state.persistSettings()
        }
        Button("Decrease Line Spacing") {
            state.settings.readerLineSpacing = max(0.7, state.settings.readerLineSpacing - 0.1)
            state.persistSettings()
        }
        Button("Increase Word Spacing") {
            state.settings.readerWordSpacing = min(12, state.settings.readerWordSpacing + 1)
            state.persistSettings()
        }
        Button("Decrease Word Spacing") {
            state.settings.readerWordSpacing = max(0, state.settings.readerWordSpacing - 1)
            state.persistSettings()
        }
        Button("Wider Margins") {
            state.settings.readerMargin = min(96, state.settings.readerMargin + 4)
            state.persistSettings()
        }
        Button("Narrower Margins") {
            state.settings.readerMargin = max(16, state.settings.readerMargin - 4)
            state.persistSettings()
        }
    }

    private var transcribeBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(state.transcriptionProgress?.message ?? "Transcribing…")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.gold)
                Spacer()
                Button("Cancel") { state.cancelTranscription() }
                    .controlSize(.small)
            }
            ProgressView(value: state.transcriptionProgress?.fraction ?? 0)
                .tint(Palette.gold)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Palette.goldSoft)
    }

    private var effectiveLookupWidth: CGFloat {
        lookupWidth > 0 ? lookupWidth : CGFloat(state.settings.lookupPanelWidth)
    }

    private var lyricPane: some View {
        GeometryReader { geo in
            let lookupOpen = state.selectedWord != nil || state.showChapterAssistant
            let split = min(max(effectiveLookupWidth, 280), max(280, geo.size.width - 320))
            let textWidth = lookupOpen ? geo.size.width - split - 8 : geo.size.width
            let type = ReaderType.metrics(
                columnWidth: textWidth,
                scale: state.settings.readerFontScale,
                lineSpacing: state.settings.readerLineSpacing,
                wordSpacing: state.settings.readerWordSpacing,
                font: state.settings.readerFont,
                bold: state.settings.readerBold
            )
            HStack(spacing: 0) {
                textColumn(proxyWidth: textWidth, type: type)
                    .frame(width: textWidth)
                if lookupOpen {
                    lookupSplitter(maxWidth: geo.size.width)
                    Group {
                        if state.showChapterAssistant {
                            ChapterAssistantView(state: state)
                                .frame(width: split)
                        } else {
                            WordInspector(state: state, type: type)
                                .frame(width: split)
                        }
                    }
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .onAppear {
            if lookupWidth <= 0 {
                lookupWidth = CGFloat(state.settings.lookupPanelWidth)
            }
        }
    }

    private func lookupSplitter(maxWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Palette.line)
            .frame(width: 8)
            .overlay {
                Capsule()
                    .fill(Palette.mute.opacity(0.55))
                    .frame(width: 3, height: 36)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = lookupDragStart ?? effectiveLookupWidth
                        if lookupDragStart == nil { lookupDragStart = start }
                        let next = start - value.translation.width
                        lookupWidth = min(max(next, 280), max(280, maxWidth - 320))
                    }
                    .onEnded { _ in
                        lookupDragStart = nil
                        state.settings.lookupPanelWidth = Double(lookupWidth)
                        state.persistSettings()
                    }
            )
                .onHover { hovering in
#if os(macOS)
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
#endif
                }
    }

    private func textColumn(proxyWidth: CGFloat, type: ReaderType) -> some View {
        let readerPosition = state.currentReaderPosition
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: type.paragraph) {
                if let transcript = state.transcript {
                    ForEach(transcript.segments) { segment in
                        SentenceRow(
                            segment: segment,
                            currentID: readerPosition.segment?.id,
                            currentWordID: readerPosition.word?.id,
                            focusedSegmentID: state.focusedSegmentID,
                            focusedWordID: state.focusedWordID,
                            textSource: state.textSource,
                            gloss: state.sentenceGloss(for: segment),
                            isTranslating: state.isLLMJobActive(kind: .sentenceTranslation, targetID: segment.id),
                            languageLabel: state.studyLanguage.menuLabel,
                            onSeek: { time in
                                state.focusedSegmentID = segment.id
                                state.focusedWordID = nil
                                state.player.seek(time)
                                if state.settings.playOnSelect, !state.player.isPlaying {
                                    state.player.play()
                                }
                            },
                            onPlayFrom: { time in
                                state.focusedSegmentID = segment.id
                                state.player.seek(time)
                                state.player.play()
                            },
                            onInspect: { word in
                                state.focusedSegmentID = segment.id
                                state.focusedWordID = word.id
                                state.inspect(word: word)
                            },
                            onSave: { word in state.addVocab(word: word, segment: segment) },
                            onTranslate: { state.translateCurrentSentence() },
                            onAccept: { if let g = state.sentenceGloss(for: segment) { state.acceptGloss(g) } },
                            onReject: { if let g = state.sentenceGloss(for: segment) { state.rejectGloss(g) } },
                            onRetry: { state.retranslateSentence(segment) },
                            type: type
                        )
                        .id(segment.id)
                    }
                } else if state.selectedChapter != nil {
                    emptyTranscript
                } else {
                    Text("Pick a book from the library.")
                        .foregroundStyle(Palette.dim)
                        .padding(40)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, min(CGFloat(state.settings.readerMargin), max(16, proxyWidth * 0.22)))
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition(id: readerScrollBinding, anchor: .center)
        .onChange(of: currentReaderScrollTarget) { oldTarget, newTarget in
            guard autoScroll else { return }
            guard let newTarget else {
                readerScrollTarget = nil
                return
            }
            if ReaderScrollTarget.shouldAnimate(from: oldTarget, to: newTarget) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    readerScrollTarget = newTarget
                }
            } else {
                readerScrollTarget = newTarget
            }
        }
        .onChange(of: state.revealToken, initial: true) { _, _ in
            guard let chapterID = state.selectedChapterID,
                  let segmentID = state.scrollSegmentID
            else { return }
            let target = ReaderScrollTarget(chapterID: chapterID, segmentID: segmentID)
            if ReaderScrollTarget.shouldAnimate(from: readerScrollTarget, to: target) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    readerScrollTarget = target
                }
            } else {
                readerScrollTarget = target
            }
        }
    }

    private var currentReaderScrollTarget: ReaderScrollTarget? {
        guard let chapterID = state.selectedChapterID,
              let segmentID = state.currentSegment?.id
        else { return nil }
        return ReaderScrollTarget(chapterID: chapterID, segmentID: segmentID)
    }

    private var readerScrollBinding: Binding<String?> {
        Binding(
            get: {
                readerScrollTarget?.segmentID(for: state.selectedChapterID)
            },
            set: { segmentID in
                guard let chapterID = state.selectedChapterID, let segmentID else {
                    readerScrollTarget = nil
                    return
                }
                readerScrollTarget = ReaderScrollTarget(chapterID: chapterID, segmentID: segmentID)
            }
        )
    }

    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prepare this chapter")
                .font(.system(size: 28, weight: .regular, design: .serif))
                .foregroundStyle(Palette.ink)
            Text("This app transcribes the audio on your Mac so every spoken word can be highlighted. Ebooks rarely match audiobooks exactly — publisher intros, number wording, and abridgements all drift — so speech-to-text is the source of timing, then we align the ebook when it helps.")
                .foregroundStyle(Palette.dim)
                .font(.system(size: 14))
                .frame(maxWidth: 560, alignment: .leading)
            Button {
                state.transcribeSelected()
            } label: {
                Label("Transcribe chapter", systemImage: "waveform.badge.mic")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.terracotta)
            .controlSize(.large)
            .disabled(state.isTranscribing)
        }
        .padding(.top, 40)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(formatClock(state.player.currentTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                    .frame(width: 54, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { state.player.currentTime },
                        set: { state.player.seek($0) }
                    ),
                    in: 0...max(state.player.duration, 0.1)
                )
                .tint(Palette.gold)
                Text(formatClock(state.player.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                    .frame(width: 54, alignment: .trailing)
            }

#if os(iOS)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    iPadTransportControls
                    Divider().frame(height: 22)
                    iPadReplayControls
                    Spacer(minLength: 4)
                    iPadSpeedMenu
                    iPadChapterNavigator
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(spacing: 6) {
                    HStack(spacing: 16) {
                        iPadTransportControls
                    }
                    .frame(maxWidth: .infinity)
                    HStack(spacing: 10) {
                        iPadReplayControls
                        iPadSpeedMenu
                        Spacer(minLength: 4)
                        iPadChapterNavigator
                    }
                    .frame(maxWidth: .infinity)
                }
            }
#else
            HStack(spacing: 18) {
                Button { state.player.skip(seconds: -state.settings.skipSeconds) } label: {
                    Image(systemName: "gobackward.5")
                }
                .help("Back \(Int(state.settings.skipSeconds))s")

                Button { state.skipSentence(direction: -1) } label: {
                    Image(systemName: "backward.end.fill")
                }
                .help("Previous sentence")

                Button { state.togglePlay() } label: {
                    Image(systemName: state.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Palette.gold)
                }
                .help("Play / Pause")

                Button { state.skipSentence(direction: 1) } label: {
                    Image(systemName: "forward.end.fill")
                }
                .help("Next sentence")

                Button { state.player.skip(seconds: state.settings.skipSeconds) } label: {
                    Image(systemName: "goforward.5")
                }
                .help("Forward \(Int(state.settings.skipSeconds))s")

                Divider().frame(height: 18)

                Button { state.replaySentence() } label: {
                    Image(systemName: "repeat.1")
                }
                .help("Replay sentence")

                Toggle(isOn: $state.loopSentence) {
                    Image(systemName: "repeat")
                }
                .toggleStyle(.button)
                .help("Loop current sentence")
                .foregroundStyle(state.loopSentence ? Palette.gold : Palette.ink)

                Spacer()

                Text("Speed")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                Slider(
                    value: Binding(
                        get: { Double(state.player.rate) },
                        set: { v in
                            state.player.rate = Float(v)
                            state.persistSettings()
                        }
                    ),
                    in: 0.7...1.6,
                    step: 0.05
                )
                .frame(width: 120)
                Text(String(format: "%.2fx", state.player.rate))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                    .frame(width: 44)

                if let chapters = state.selectedBook?.chapters, chapters.count > 1 {
                    Button { state.openPreviousChapter() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Previous chapter")
                    .accessibilityLabel("Previous chapter")
                    .disabled(!state.canOpenPreviousChapter)

                    Picker("Chapter", selection: Binding(
                        get: { state.selectedChapterID ?? "" },
                        set: { id in
                            if let book = state.selectedBook, let ch = book.chapters.first(where: { $0.id == id }) {
                                state.open(chapter: ch, in: book, autoplay: state.player.isPlaying)
                            }
                        }
                    )) {
                        ForEach(chapters) { ch in
                            Text(ch.title).tag(ch.id)
                        }
                    }
                    .frame(maxWidth: 200)

                    Button { state.openNextChapter() } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help("Next chapter")
                    .accessibilityLabel("Next chapter")
                    .disabled(!state.canOpenNextChapter)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink)
            .font(.system(size: 16))
#endif
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Palette.panel)
    }

#if os(iOS)
    private var iPadTransportControls: some View {
        HStack(spacing: 10) {
            Button { state.player.skip(seconds: -state.settings.skipSeconds) } label: {
                Image(systemName: "gobackward.5")
                    .frame(width: 36, height: 44)
            }
            Button { state.skipSentence(direction: -1) } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: 40, height: 44)
            }
            Button { state.togglePlay() } label: {
                Image(systemName: state.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Palette.gold)
                    .frame(width: 36, height: 44)
            }
            Button { state.skipSentence(direction: 1) } label: {
                Image(systemName: "forward.end.fill")
                    .frame(width: 36, height: 44)
            }
            Button { state.player.skip(seconds: state.settings.skipSeconds) } label: {
                Image(systemName: "goforward.5")
                    .frame(width: 36, height: 44)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .font(.system(size: 16))
        .frame(minHeight: 44)
    }

    private var iPadReplayControls: some View {
        HStack(spacing: 8) {
            Button { state.replaySentence() } label: {
                Image(systemName: "repeat.1")
                    .frame(width: 36, height: 44)
            }
            Toggle(isOn: $state.loopSentence) {
                Image(systemName: "repeat")
                    .frame(width: 44, height: 44)
            }
            .toggleStyle(.button)
            .foregroundStyle(state.loopSentence ? Palette.gold : Palette.ink)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .font(.system(size: 16))
        .frame(minHeight: 44)
    }

    private var iPadSpeedMenu: some View {
        Button {
            showSpeedPicker.toggle()
        } label: {
            Label(String(format: "%.2fx", state.player.rate), systemImage: "speedometer")
                .lineLimit(1)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.terracotta)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(Palette.goldSoft, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(String(format: "%.2f times", state.player.rate))
        .popover(isPresented: $showSpeedPicker, arrowEdge: .bottom) {
            IPadPlaybackSpeedPicker(state: state) {
                showSpeedPicker = false
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var iPadChapterNavigator: some View {
        if let chapters = state.selectedBook?.chapters, chapters.count > 1 {
            HStack(spacing: 2) {
                Button { state.openPreviousChapter() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 36, height: 44)
                }
                .disabled(!state.canOpenPreviousChapter)
                .accessibilityLabel("Previous chapter")

                Menu {
                    Picker("Chapter", selection: Binding(
                        get: { state.selectedChapterID ?? "" },
                        set: { id in
                            if let book = state.selectedBook,
                               let chapter = book.chapters.first(where: { $0.id == id }) {
                                state.open(chapter: chapter, in: book, autoplay: state.player.isPlaying)
                            }
                        }
                    )) {
                        ForEach(chapters) { chapter in
                            Text(chapter.title).tag(chapter.id)
                        }
                    }
                } label: {
                    Label(chapterPositionLabel(in: chapters), systemImage: "list.bullet")
                        .lineLimit(1)
                }
                .fixedSize()
                .frame(minHeight: 44)

                Button { state.openNextChapter() } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 36, height: 44)
                }
                .disabled(!state.canOpenNextChapter)
                .accessibilityLabel("Next chapter")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func chapterPositionLabel(in chapters: [Chapter]) -> String {
        let index = chapters.firstIndex { $0.id == state.selectedChapterID } ?? 0
        return "Chapter \(index + 1) of \(chapters.count)"
    }
#endif
}

#if os(iOS)
private struct IPadPlaybackSpeedPicker: View {
    @Bindable var state: AppState
    let onDismiss: () -> Void

    private var selectedSpeed: Double {
        Double(state.player.rate)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Playback Speed")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.2fx", state.player.rate))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Palette.terracotta)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(PlaybackSpeedCatalog.values, id: \.self) { speed in
                            speedRow(speed)
                                .id(speed)
                            if speed != PlaybackSpeedCatalog.values.last {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
                .onAppear {
                    proxy.scrollTo(nearestCatalogSpeed, anchor: .center)
                }
            }
        }
        .frame(width: 250, height: 430)
        .background(Color(uiColor: .systemBackground))
    }

    private func speedRow(_ speed: Double) -> some View {
        let selected = abs(selectedSpeed - speed) < 0.001
        return Button {
            state.player.rate = Float(speed)
            state.persistSettings()
            onDismiss()
        } label: {
            HStack {
                Text(String(format: "%.2fx", speed))
                    .font(.body.monospacedDigit())
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.weight(.semibold))
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(selected ? Palette.terracotta : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: "%.2f times", speed))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var nearestCatalogSpeed: Double {
        PlaybackSpeedCatalog.values.min(by: {
            abs($0 - selectedSpeed) < abs($1 - selectedSpeed)
        }) ?? 1.0
    }
}
#endif

private struct ChapterAssistantView: View {
    @Bindable var state: AppState
    @State private var chatDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chapter AI")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.mute)
                        .textCase(.uppercase)
                        .tracking(0.8)
                    Text(state.selectedLLMModel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.gold)
                }
                Spacer()
                Button {
                    state.showChapterAssistant = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.dim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.selectedBook?.title ?? "Unknown book")
                            .font(.system(size: 17, weight: .semibold, design: .serif))
                        Text([state.selectedBook?.author, state.selectedChapter?.title].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.dim)
                    }

                    HStack {
                        Menu {
                            if state.selectedChapterTranslationCheckpoint?.status == .inProgress {
                                Button("Continue from last stop") {
                                    state.translateChapter(mode: .continueFromCheckpoint)
                                }
                            }
                            Button("Translate untranslated sentences") {
                                state.translateChapter(mode: .untranslatedOnly)
                            }
                            Button("Retranslate whole chapter") {
                                state.translateChapter(mode: .retranslateAll)
                            }
                        } label: {
                            Label("Translate chapter", systemImage: "globe")
                        }
                        Button {
                            state.summarizeChapter()
                        } label: {
                            Label("Summarise", systemImage: "text.alignleft")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.transcript == nil)

                    if let checkpoint = state.selectedChapterTranslationCheckpoint {
                        Label(chapterTranslationStatus(checkpoint), systemImage: "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.dim)
                    }

                    if let progress = state.chapterAcceptanceProgress {
                        assistantCard(title: progress.stage) {
                            ProgressView(value: progress.fraction)
                            Text(progress.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if !state.pendingChapterSentenceGlosses.isEmpty {
                        assistantCard(title: "Pending review") {
                            Text("\(state.pendingChapterSentenceGlosses.count) sentence translation(s) are ready for review in this chapter.")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.dim)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Accept all pending") {
                                state.acceptAllChapterTranslations()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.terracotta)
                        }
                    }

                    if state.isChapterAssistantWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Asking \(state.selectedLLMModel)…")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.dim)
                            Spacer()
                            if state.selectedChapterTranslationJobState == .running {
                                Button(state.chapterTranslationStopRequested ? "Stopping…" : "Stop after block") {
                                    state.requestChapterTranslationStop()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(state.chapterTranslationStopRequested)
                            }
                        }
                    }

                    if let progress = state.chapterTranslationProgress {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: progress.fraction)
                            Text(progress.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.dim)
                        }
                    }

                    if let error = state.chapterAssistantError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(.red.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                            if state.chapterTranslationFailed {
                                Button("Retry remaining") {
                                    state.translateChapter(mode: .continueFromCheckpoint)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Palette.terracotta)
                            }
                        }
                    }

                    if let summary = state.chapterSummary {
                        assistantCard(title: "Chapter summary") {
                            GlossBody(text: summary, size: 14)
                        }
                    }

                    if let translation = state.chapterTranslation {
                        assistantCard(title: "Chapter translation") {
                            Text(translation)
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    assistantCard(title: "Ask about this passage") {
                        if state.chapterChat.isEmpty {
                            Text("Questions include the book, author, chapter, and \(state.settings.chatContextCount) nearby sentences on each side.")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.dim)
                        }
                        ForEach(state.chapterChat) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.role == .user ? "You" : state.selectedLLMModel)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(message.role == .user ? Palette.mute : Palette.gold)
                                Text(message.text)
                                    .font(.system(size: 13, design: .serif))
                                    .foregroundStyle(Palette.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(message.role == .user ? Palette.panel : Palette.goldSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                        HStack(alignment: .bottom) {
                            TextField("Ask about the chapter…", text: $chatDraft, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...5)
                                .onSubmit { sendChat() }
                            Button(action: sendChat) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 22))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.gold)
                            .disabled(chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.panel)
        .overlay(Rectangle().fill(Palette.line).frame(width: 1), alignment: .leading)
    }

    private func sendChat() {
        let question = chatDraft
        chatDraft = ""
        state.sendChapterChat(question)
    }

    private func chapterTranslationStatus(_ checkpoint: ChapterTranslationCheckpoint) -> String {
        switch checkpoint.status {
        case .inProgress:
            "Saved through sentence \(min(checkpoint.nextSegmentIndex, checkpoint.totalSentences)) of \(checkpoint.totalSentences)"
        case .awaitingReview:
            "All translated · waiting for review"
        case .allAccepted:
            "All translations accepted"
        }
    }

    private func assistantCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.mute)
                .textCase(.uppercase)
                .tracking(0.6)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct SentenceRow: View {
    let segment: TranscriptSegment
    let currentID: String?
    let currentWordID: String?
    let focusedSegmentID: String?
    let focusedWordID: String?
    let textSource: TextSource
    let gloss: GlossEntry?
    let isTranslating: Bool
    let languageLabel: String
    let onSeek: (TimeInterval) -> Void
    let onPlayFrom: (TimeInterval) -> Void
    let onInspect: (TranscriptWord) -> Void
    let onSave: (TranscriptWord) -> Void
    let onTranslate: () -> Void
    let onAccept: () -> Void
    let onReject: () -> Void
    let onRetry: () -> Void
    let type: ReaderType

    private var isCurrent: Bool { segment.id == currentID }
    private var isFocused: Bool { segment.id == focusedSegmentID }
    private var isSelected: Bool { isCurrent || isFocused }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(formatClock(segment.start))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isSelected ? Palette.gold : Palette.mute)
                if let score = segment.alignmentScore, score >= 0.52 {
                    Text("ebook matched")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.mute)
                }
            }

            if textSource == .spoken || textSource == .dual {
                if isSelected {
                    FlowLayout(spacing: type.word, lineSpacing: type.line) {
                        ForEach(segment.words) { word in
                            WordToken(
                                word: word,
                                isCurrent: word.id == currentWordID || word.id == focusedWordID,
                                dimmed: false,
                                fontSize: type.body,
                                font: type.font,
                                bold: type.bold,
                                onSeek: { onSeek(word.start) },
                                onPlayFrom: { onPlayFrom(word.start) },
                                onInspect: { onInspect(word) },
                                onSave: { onSave(word) }
                            )
                        }
                    }
                } else {
                    Text(segment.spokenText)
                        .font(type.font.font(size: type.body, bold: type.bold))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(type.line)
                }
            }

            if textSource == .original || textSource == .dual {
                let original = segment.ebookText ?? (textSource == .original ? segment.spokenText : nil)
                if let original {
                    Text(original)
                        .font(type.font.font(size: textSource == .dual ? type.dual : type.body, bold: type.bold))
                        .foregroundStyle(isSelected ? Palette.ink : Palette.dim)
                        .italic(textSource == .dual)
                        .lineSpacing(type.line)
                }
            }

            if isSelected {
                translationBlock
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Palette.goldSoft : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isFocused && !isCurrent ? Palette.gold.opacity(0.55) : Color.clear, lineWidth: 1.5)
        )
        .onTapGesture { onSeek(segment.start) }
        .opacity(isSelected ? 1 : 0.72)
    }

    @ViewBuilder
    private var translationBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isTranslating && gloss == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("The LLM is translating…")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.dim)
                }
            } else if let gloss {
                GlossBody(text: gloss.text, size: type.gloss)
                HStack(spacing: 8) {
                    if gloss.status == .pending {
                        Text("Draft · Model: \(gloss.model)")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.gold)
                        Button("Accept", action: onAccept)
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.terracotta)
                            .controlSize(.small)
                        Button("Reject", action: onReject)
                            .controlSize(.small)
                        Button("Retranslate", action: onRetry)
                            .controlSize(.small)
                    } else if gloss.status == .accepted {
                        Text("Saved · Model: \(gloss.model)")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.gold)
                        Button("Retranslate", action: onRetry)
                            .controlSize(.small)
                    }
                }
            } else {
                Button(action: onTranslate) {
                    Label("Translate into \(languageLabel)", systemImage: "globe")
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 4)
    }
}

private struct WordToken: View {
    let word: TranscriptWord
    let isCurrent: Bool
    let dimmed: Bool
    var fontSize: CGFloat = 22
    var font: ReaderFontChoice = .newYork
    var bold = false
    let onSeek: () -> Void
    let onPlayFrom: () -> Void
    let onInspect: () -> Void
    let onSave: () -> Void

    var body: some View {
        Text(word.text)
            .font(font.font(size: fontSize, bold: bold || isCurrent))
            .foregroundStyle(isCurrent ? Palette.inkOnGold : (dimmed ? Palette.dim : Palette.ink))
            .padding(.horizontal, isCurrent ? 4 : 0)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isCurrent ? Palette.gold : Color.clear)
            )
            .onTapGesture { onSeek(); onInspect() }
            .contextMenu {
                Button("Play from here", action: onPlayFrom)
                Button("Look up", action: onInspect)
                Button("Add to vocabulary", action: onSave)
            }
    }
}

private struct WordInspector: View {
    @Bindable var state: AppState
    var type: ReaderType = .metrics(columnWidth: 420, scale: 1)
    @Environment(\.colorScheme) private var colorScheme
    @State private var webHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Lookup")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.mute)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
                Button {
                    state.selectedWord = nil
                    state.definition = nil
                    state.dictionaryHits = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.dim)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 8)

            if let word = state.selectedWord {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(DictionaryLookup.headword(word.text))
                                .font(.system(size: max(24, type.body * 1.35), weight: .regular, design: .serif))
                                .foregroundStyle(Palette.ink)
                                .textSelection(.enabled)
                            if let seg = contextSegment {
                                Text(seg.displayText)
                                    .font(.system(size: 13, design: .serif))
                                    .italic()
                                    .foregroundStyle(Palette.dim)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineSpacing(4)
                            }
                        }

                        inspectorCard(title: "Apple Dictionary") {
#if os(iOS)
                            if DictionaryLookup.hasSystemDefinition(word.text) {
                                SystemDictionaryView(term: word.text)
                                    .id(DictionaryLookup.headword(word.text))
                                    .frame(minHeight: 360, idealHeight: 480)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Text("iPadOS shows entries from its installed dictionaries. Dictionary ordering and selection are managed by iPadOS.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.dim)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("No definition is currently available from the dictionaries installed in iPadOS.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.dim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Button {
                                DictionaryLookup.lookUpInDictionary(word.text)
                            } label: {
                                Label("Open Dictionary Full Screen", systemImage: "book")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.terracotta)
#else
                            if state.dictionaryHits.isEmpty {
                                Text("No entries in the installed dictionaries.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.dim)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Picker("Dictionary", selection: $state.selectedDictionaryName) {
                                    ForEach(state.dictionaryHits) { hit in
                                        Text(hit.name).tag(hit.name)
                                    }
                                }
                                .labelsHidden()
                                .onChange(of: state.selectedDictionaryName) { _, name in
                                    state.settings.preferredDictionary = name
                                    state.persistSettings()
                                    webHeight = 180
                                }

                                if let hit = state.selectedDictionaryHit {
                                    DictionaryHTMLView(html: hit.html, dark: colorScheme == .dark, height: $webHeight)
                                        .frame(height: webHeight)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                            Button {
                                DictionaryLookup.lookUpInDictionary(word.text)
                            } label: {
                                Label("Open in Dictionary.app", systemImage: "book")
                                    .frame(maxWidth: .infinity)
                            }
#endif
                        }

                        inspectorCard(title: "In this sentence") {
                            if let gloss = state.selectedWordGloss {
                                GlossBody(text: gloss.text, size: type.gloss)
                                if gloss.status == .pending {
                                    Text("Draft from \(gloss.model). Accept to keep it in the library.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.gold)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 10) {
                                        Button("Accept") { state.acceptGloss(gloss) }
                                            .buttonStyle(.borderedProminent)
                                            .tint(Palette.terracotta)
                                        Button("Reject") { state.rejectGloss(gloss) }
                                    }
                                } else if gloss.status == .accepted {
                                    Text("Saved · Model: \(gloss.model)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.gold)
                                }
                                Button("Retranslate") { state.retranslateSelectedWord() }
                                    .buttonStyle(.bordered)
                            } else if state.isLLMJobActive(kind: .wordTranslation, targetID: word.id) {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text("Asking \(state.selectedLLMModel)…")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.dim)
                                }
                                .padding(.vertical, 8)
                            } else {
                                Button {
                                    state.translateSelectedWord()
                                } label: {
                                    Label("This-sentence meaning (\(state.selectedLLMModel))", systemImage: "globe")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                            if let err = state.translationError {
                                Text(err)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if let seg = contextSegment {
                            let isSaved = state.isInVocabulary(word: word)
                            Button {
                                state.addVocab(word: word, segment: seg)
                            } label: {
                                Label(isSaved ? "Already in vocabulary" : "Add to vocabulary", systemImage: isSaved ? "checkmark.circle.fill" : "bookmark")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.terracotta)
                            .controlSize(.large)
                            .disabled(isSaved)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 32)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.panel)
        .overlay(Rectangle().fill(Palette.line).frame(width: 1), alignment: .leading)
    }

    private var contextSegment: TranscriptSegment? {
        if let id = state.focusedSegmentID {
            return state.transcript?.segments.first { $0.id == id }
        }
        return state.currentSegment
    }

    private func inspectorCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.mute)
                .textCase(.uppercase)
                .tracking(0.6)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct GlossBody: View {
    let text: String
    var size: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                Text(block.text)
                    .font(.system(size: block.isHeading ? max(11, size * 0.78) : size, weight: block.isHeading ? .semibold : .regular, design: .serif))
                    .foregroundStyle(block.isHeading ? Palette.gold : Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(block.isBullet ? 4 : 6)
                    .padding(.leading, block.isBullet ? 10 : 0)
                    .textSelection(.enabled)
            }
        }
    }

    private var blocks: [Block] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            let isHeading = line.hasPrefix("译文") || line.hasPrefix("短语")
                || line.hasPrefix("本句释义") || line.hasPrefix("例句") || line.hasPrefix("释义")
            let isBullet = line.hasPrefix("•") || line.hasPrefix("- ") || line.hasPrefix("·")
            return Block(text: line.isEmpty ? " " : line, isHeading: isHeading, isBullet: isBullet)
        }
    }

    private struct Block {
        var text: String
        var isHeading: Bool
        var isBullet: Bool
    }
}
