import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
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
    @State private var showSpeedPicker = false
    @State private var showReplaceEbookImporter = false
#endif

    var body: some View {
        VStack(spacing: 0) {
#if os(macOS)
            header
            Divider().overlay(Palette.line)
#endif
            if state.isTranscribing {
                transcribeBanner
            }
            if let mismatch = state.transcriptionLanguageMismatch {
                transcriptionLanguageNotice(mismatch)
            }
            if state.currentBookIsMissingEbook {
                ebookMissingNotice
            } else if let assessment = state.currentEbookAlignment {
                ebookAlignmentNotice(assessment)
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
            VStack(spacing: playbackChromeSpacing) {
                PlaybackChrome(state: state)
#if os(iOS)
                iPadCompactPlaybackBar
#else
                ViewThatFits(in: .horizontal) {
                    desktopExpandedPlaybackControls
                    desktopCompactPlaybackControls
                }
#endif
            }
            .padding(.horizontal, playbackChromeHorizontalPadding)
            .padding(.top, playbackChromeTopPadding)
            .padding(.bottom, playbackChromeBottomPadding)
            .background(Palette.panel)
        }
        .background(Palette.bg)
        .navigationTitle(readerNavigationTitle)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            iPadReaderToolbar
        }
        .fileImporter(isPresented: $showReplaceEbookImporter, allowedContentTypes: [.epub]) { result in
            do {
                try state.replaceCurrentEbook(with: result.get())
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
#endif
        .sheet(item: $state.shadowingSegment) { segment in
            ShadowingPracticeView(state: state, segment: segment)
        }
        .sheet(item: $state.chapterQuizSession) { _ in
            ChapterQuizView(state: state)
        }
    }

    private var ebookMissingNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed.fill")
                .foregroundStyle(Palette.terracotta)
            VStack(alignment: .leading, spacing: 2) {
                Text("EPUB ebook missing")
                    .font(.system(size: 12, weight: .semibold))
                Text("Add a companion EPUB to compare the published text with the audiobook and enable synchronized ebook reading.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
            }
            Spacer()
            Button("Add EPUB") { addOrReplaceEbook() }
                .buttonStyle(.borderedProminent)
                .tint(Palette.terracotta)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.goldSoft)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("EPUB ebook missing. Add EPUB")
    }

    private func transcriptionLanguageNotice(_ mismatch: TranscriptionLanguageMismatch) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.exclamationmark")
                .foregroundStyle(Palette.terracotta)
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcript language may be wrong")
                    .font(.system(size: 12, weight: .semibold))
                Text("This transcript was created as \(mismatch.transcribedLanguage.menuLabel), but the text looks like \(mismatch.detectedLanguage.menuLabel).")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
            }
            Spacer()
            Button("Re-transcribe in \(mismatch.detectedLanguage.menuLabel)") {
                state.useSuggestedTranscriptionLanguage(mismatch.detectedLanguage)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.terracotta)
            Button("Keep current transcript") {
                state.dismissTranscriptionLanguageMismatch()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.goldSoft)
        .accessibilityElement(children: .contain)
    }

    private func ebookAlignmentNotice(_ assessment: EPUBAlignmentAssessment) -> some View {
        HStack(spacing: 12) {
            Image(systemName: assessment.status == .trusted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(assessment.status == .trusted ? Color.green : Palette.terracotta)
            VStack(alignment: .leading, spacing: 2) {
                Text(assessment.status.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(state.transcript?.ebookUseOverride == true
                    ? "Using individually verified EPUB matches by your explicit choice."
                    : assessment.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
            }
            Spacer()
            if assessment.status != .trusted {
                Button("Recheck EPUB") {
                    Task { await state.recheckCurrentEbookAlignment() }
                }
                .buttonStyle(.bordered)
                .disabled(state.isRecheckingEbook || state.transcript == nil)
                Button("Replace EPUB") { addOrReplaceEbook() }
                    .buttonStyle(.bordered)
                if state.canUseCurrentEbookAnyway {
                    Button("Use This EPUB Anyway") { state.useCurrentEbookAnyway() }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.terracotta)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(assessment.status == .trusted ? Color.green.opacity(0.08) : Palette.goldSoft)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("EPUB alignment status: \(assessment.status.title)")
    }

    private func addOrReplaceEbook() {
#if os(macOS)
        guard let book = state.selectedBook else { return }
        do {
            guard let url = try MacAudiobookImporter.chooseEbook(
                for: book,
                replacingExisting: book.ebookPath != nil
            ) else { return }
            try state.replaceCurrentEbook(with: url)
        } catch {
            state.errorMessage = error.localizedDescription
        }
#else
        showReplaceEbookImporter = true
#endif
    }

#if os(macOS)
    private var header: some View {
        desktopHeader
    }

    private var desktopHeader: some View {
        ViewThatFits(in: .horizontal) {
            desktopExpandedHeaderControls
            desktopCompactHeaderControls
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Palette.panel)
    }

    private var desktopExpandedHeaderControls: some View {
        HStack(spacing: 14) {
            textSourcePicker
                .labelsHidden()
                .frame(width: 220)
            desktopProviderControls

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

            Toggle("Study overlay", isOn: $state.settings.showStudyOverlay)
                .toggleStyle(.switch)
                .controlSize(.small)
                .foregroundStyle(Palette.dim)
                .onChange(of: state.settings.showStudyOverlay) { _, _ in state.persistSettings() }
                .help("Underline unknown and learning words in the chapter.")
                .accessibilityHint("Underlines unknown and learning words throughout the chapter.")

            Button("Chapter words") {
                state.presentChapterStudyList()
            }
            .disabled(state.transcript == nil)

            Menu {
                Toggle("Study overlay", isOn: $state.settings.showStudyOverlay)
                    .onChange(of: state.settings.showStudyOverlay) { _, _ in state.persistSettings() }
                Button("Shadow this sentence") {
                    state.presentShadowing()
                }
                .disabled(state.transcript == nil)
                Button("Chapter quiz") {
                    state.presentChapterQuiz()
                }
                .disabled(state.transcript == nil)
                Divider()
                readingAppearanceMenuContent
            } label: {
                Label("Reading", systemImage: "textformat")
            }

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
        .fixedSize(horizontal: true, vertical: false)
    }

    private var desktopCompactHeaderControls: some View {
        HStack(spacing: 10) {
            textSourcePicker
                .labelsHidden()
                .frame(width: 220)
            Spacer(minLength: 0)
            sharedLLMMenu
            sharedReadingMenu
            Button {
                state.showChapterAssistant.toggle()
            } label: {
                Image(systemName: "sparkles")
            }
            .foregroundStyle(state.showChapterAssistant ? Palette.gold : Palette.ink)
            .disabled(state.selectedChapter == nil)
            .accessibilityLabel("Chapter AI")
            .help("Chapter AI")

            Button {
                state.transcribeSelected(force: state.transcript != nil)
            } label: {
                Image(systemName: "waveform")
            }
            .disabled(state.selectedChapter == nil || state.isTranscribing)
            .accessibilityLabel(state.transcript == nil ? "Transcribe" : "Re-transcribe")
            .help(state.transcript == nil ? "Transcribe chapter" : "Re-transcribe chapter")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var desktopProviderControls: some View {
        Picker("Connection", selection: llmConnectionBinding) {
            ForEach(LLMConnectionChoice.availableOnCurrentPlatform) { connection in
                Text(connection.menuLabel).tag(connection)
            }
        }
        .frame(maxWidth: 210)

        switch state.llmProvider {
        case .grok:
            Picker("Model", selection: $state.settings.grokModel) {
                ForEach(state.grokTextModels) { model in
                    Text(model.id).tag(model.id)
                }
            }
            .frame(maxWidth: 140)
            .onChange(of: state.settings.grokModel) { _, _ in
                state.persistSettings()
                state.normalizeSelectedGrokEffort()
            }

            if !state.selectedGrokEfforts.isEmpty {
                Picker("Effort", selection: $state.settings.grokEffort) {
                    ForEach(state.selectedGrokEfforts) { effort in
                        Text(effort.rawValue).tag(effort.rawValue)
                    }
                }
                .frame(maxWidth: 110)
                .onChange(of: state.settings.grokEffort) { _, _ in state.persistSettings() }
            }
        case .qwenCloud:
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
        case .openAI:
            Picker("Model", selection: $state.settings.openAIModel) {
                ForEach(state.openAITextModels) { model in
                    Text(model.id).tag(model.id)
                }
            }
            .frame(maxWidth: 180)
            .onChange(of: state.settings.openAIModel) { _, _ in
                state.persistSettings()
                state.normalizeSelectedOpenAIEffort()
            }
            if !state.selectedOpenAIEfforts.isEmpty {
                Picker("Effort", selection: $state.settings.openAIEffort) {
                    ForEach(state.selectedOpenAIEfforts) { effort in
                        Text(effort.rawValue).tag(effort.rawValue)
                    }
                }
                .frame(maxWidth: 105)
                .onChange(of: state.settings.openAIEffort) { _, _ in state.persistSettings() }
            }
        case .appleFoundation:
            Text(state.appleIntelligenceAvailability.shortLabel)
                .foregroundStyle(state.appleIntelligenceAvailability.isReady ? Palette.gold : Palette.dim)
                .help(state.appleIntelligenceAvailability.userMessage)
        }
    }
#endif

    private var sentenceLoopBinding: Binding<Bool> {
        Binding(
            get: { state.loopSentence },
            set: { state.setSentenceLoop($0) }
        )
    }

    private var deepReadingBinding: Binding<Bool> {
        Binding(
            get: { state.settings.deepReadingMode },
            set: { state.setDeepReadingMode($0) }
        )
    }

    private var readerNavigationTitle: String {
        ReaderWindowTitle.make(
            book: state.selectedBook?.title,
            chapter: state.selectedChapter?.title,
            coverage: state.chapterCoverage
        )
    }

#if os(iOS)
    @ToolbarContentBuilder
    private var iPadReaderToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Text", selection: $state.textSource) {
                    Text(TextSource.spoken.rawValue).tag(TextSource.spoken)
                    Text(TextSource.original.rawValue).tag(TextSource.original)
                    Text(TextSource.dual.rawValue).tag(TextSource.dual)
                }
            } label: {
                Image(systemName: "book.pages")
            }
            .accessibilityLabel("Text")
            .accessibilityValue(state.textSource.rawValue)
            .onChange(of: state.textSource) { _, _ in state.persistSettings() }
        }
        ToolbarItem(placement: .primaryAction) {
            sharedLLMMenu
        }
        ToolbarItem(placement: .primaryAction) {
            sharedReadingMenu
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                state.showChapterAssistant.toggle()
            } label: {
                Image(systemName: "sparkles")
            }
            .foregroundStyle(state.showChapterAssistant ? Palette.gold : Palette.ink)
            .disabled(state.selectedChapter == nil)
            .accessibilityLabel("Chapter AI")
            .help("Chapter AI")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                state.transcribeSelected(force: state.transcript != nil)
            } label: {
                Image(systemName: "waveform")
            }
            .disabled(state.selectedChapter == nil || state.isTranscribing)
            .accessibilityLabel(state.transcript == nil ? "Transcribe" : "Re-transcribe")
            .help(state.transcript == nil ? "Transcribe chapter" : "Re-transcribe chapter")
        }
    }
#endif

#if os(macOS)
    private var textSourcePicker: some View {
        Picker("Text", selection: $state.textSource) {
            Text(TextSource.spoken.rawValue).tag(TextSource.spoken)
            Text(TextSource.original.rawValue).tag(TextSource.original)
            Text(TextSource.dual.rawValue).tag(TextSource.dual)
        }
        .pickerStyle(.segmented)
        .onChange(of: state.textSource) { _, _ in state.persistSettings() }
    }
#endif

    private var sharedLLMMenu: some View {
        Menu {
            Picker("Connection", selection: llmConnectionBinding) {
                ForEach(LLMConnectionChoice.availableOnCurrentPlatform) { connection in
                    Text(connection.menuLabel).tag(connection)
                }
            }

            switch state.llmProvider {
            case .grok:
                Picker("Model", selection: $state.settings.grokModel) {
                    ForEach(state.grokTextModels) { model in
                        Text(model.id).tag(model.id)
                    }
                }
                .onChange(of: state.settings.grokModel) { _, _ in
                    state.persistSettings()
                    state.normalizeSelectedGrokEffort()
                }

                if !state.selectedGrokEfforts.isEmpty {
                    Picker("Effort", selection: $state.settings.grokEffort) {
                        ForEach(state.selectedGrokEfforts) { effort in
                            Text(effort.rawValue).tag(effort.rawValue)
                        }
                    }
                    .onChange(of: state.settings.grokEffort) { _, _ in state.persistSettings() }
                }
            case .qwenCloud:
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
            case .openAI:
                Picker("Model", selection: $state.settings.openAIModel) {
                    ForEach(state.openAITextModels) { model in
                        Text(model.id).tag(model.id)
                    }
                }
                .onChange(of: state.settings.openAIModel) { _, _ in
                    state.persistSettings()
                    state.normalizeSelectedOpenAIEffort()
                }

                if !state.selectedOpenAIEfforts.isEmpty {
                    Picker("Effort", selection: $state.settings.openAIEffort) {
                        ForEach(state.selectedOpenAIEfforts) { effort in
                            Text(effort.rawValue).tag(effort.rawValue)
                        }
                    }
                    .onChange(of: state.settings.openAIEffort) { _, _ in state.persistSettings() }
                }
            case .appleFoundation:
                Text(state.appleIntelligenceAvailability.userMessage)
            }
        } label: {
#if os(iOS)
            Image(systemName: "brain.head.profile")
#else
            Label(state.selectedLLMConnection.compactLabel, systemImage: "brain.head.profile")
#endif
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("AI settings")
        .accessibilityValue(state.selectedLLMConnection.compactLabel)
    }

    private var sharedReadingMenu: some View {
        Menu {
            Toggle("Auto-scroll", isOn: $autoScroll)
            Toggle("Play on tap", isOn: $state.settings.playOnSelect)
                .onChange(of: state.settings.playOnSelect) { _, _ in state.persistSettings() }
            Toggle("Study overlay", isOn: $state.settings.showStudyOverlay)
                .onChange(of: state.settings.showStudyOverlay) { _, _ in state.persistSettings() }
                .accessibilityHint("Underlines unknown and learning words throughout the chapter.")
            if state.chapterCoverage.contentCount > 0 {
                Text(state.chapterCoverage.caption)
            }
            Button("Chapter words") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    state.presentChapterStudyList()
                }
            }
            .disabled(state.transcript == nil)
            Button("Shadow this sentence") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    state.presentShadowing()
                }
            }
            .disabled(state.transcript == nil)
            Button("Chapter quiz") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    state.presentChapterQuiz()
                }
            }
            .disabled(state.transcript == nil)
            if let book = state.selectedBook {
                Divider()
                AudiobookLanguagePicker(state: state, book: book)
                if let locale = state.transcript?.locale {
                    Text("Transcript: \(TranscriptionLanguage.matching(localeIdentifier: locale)?.menuLabel ?? locale)")
                }
            }
            Divider()
            readingAppearanceMenuContent
        } label: {
#if os(iOS)
            Image(systemName: "textformat")
#else
            Label("Reading", systemImage: "textformat")
#endif
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Reading settings")
    }

    private var llmConnectionBinding: Binding<LLMConnectionChoice> {
        Binding(
            get: { state.selectedLLMConnection },
            set: { connection in
                state.selectedLLMConnection = connection
                didChangeLLMConnection(to: connection)
            }
        )
    }

    private func didChangeLLMConnection(to connection: LLMConnectionChoice) {
        state.persistSettings()
        if connection == .grokAPIKey {
            Task { await state.refreshGrokModels() }
        } else if connection == .qwenAPIKey {
            Task { await state.refreshQwenModels() }
        } else if connection == .chatGPTPlan {
            Task { await state.refreshCodexLoginStatus() }
        } else if connection == .openAIAPIKey {
            Task { await state.refreshOpenAIModels() }
        } else if connection == .appleFoundation {
            state.refreshAppleIntelligenceAvailability()
        }
    }

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
            state.settings.readerFontScale = max(0.65, (state.settings.readerFontScale * 10 - 1).rounded() / 10)
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
            let split = ReaderSplitGeometry(
                containerWidth: geo.size.width,
                proposedLookupWidth: effectiveLookupWidth,
                isLookupOpen: lookupOpen
            )
            let type = ReaderType.metrics(
                columnWidth: split.textWidth,
                scale: state.settings.readerFontScale,
                lineSpacing: state.settings.readerLineSpacing,
                wordSpacing: state.settings.readerWordSpacing,
                font: state.settings.readerFont,
                bold: state.settings.readerBold
            )
            HStack(spacing: 0) {
                TranscriptTextColumn(
                    state: state,
                    autoScroll: $autoScroll,
                    readerScrollTarget: $readerScrollTarget,
                    proxyWidth: split.textWidth,
                    type: type
                )
                    .frame(width: split.textWidth)
                if lookupOpen {
                    lookupSplitter(containerWidth: geo.size.width)
                    Group {
                        if state.showChapterAssistant {
                            ChapterAssistantView(state: state)
                                .frame(width: split.lookupWidth)
                        } else {
                            WordInspector(state: state, type: type)
                                .frame(width: split.lookupWidth)
                        }
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            .onChange(of: geo.size.width) { _, width in
                lookupWidth = ReaderSplitLayout.clampedLookupWidth(
                    proposed: effectiveLookupWidth,
                    containerWidth: width
                )
            }
        }
        .onAppear {
            if lookupWidth <= 0 {
                lookupWidth = CGFloat(state.settings.lookupPanelWidth)
            }
        }
    }

    private func applyLookupDrag(translation: CGFloat, containerWidth: CGFloat) {
        let start = lookupDragStart ?? effectiveLookupWidth
        if lookupDragStart == nil { lookupDragStart = start }
        lookupWidth = ReaderSplitLayout.clampedLookupWidth(
            proposed: start - translation,
            containerWidth: containerWidth
        )
    }

    private func finishLookupDrag() {
        lookupDragStart = nil
        state.settings.lookupPanelWidth = Double(lookupWidth)
        state.persistSettings()
    }

    private func lookupSplitter(containerWidth: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Palette.line)
                .frame(width: 1)
            Capsule()
                .fill(Palette.mute.opacity(0.7))
                .frame(width: 4, height: 44)
        }
        .frame(width: ReaderSplitLayout.splitterVisualWidth)
        .contentShape(Rectangle())
        .accessibilityLabel("Resize lookup panel")
        .accessibilityValue("\(Int(effectiveLookupWidth.rounded())) points")
        .accessibilityHint("Adjust to make the reading text wider or narrower")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = 24
            switch direction {
            case .increment:
                lookupWidth = ReaderSplitLayout.clampedLookupWidth(
                    proposed: effectiveLookupWidth + step,
                    containerWidth: containerWidth
                )
            case .decrement:
                lookupWidth = ReaderSplitLayout.clampedLookupWidth(
                    proposed: effectiveLookupWidth - step,
                    containerWidth: containerWidth
                )
            @unknown default:
                break
            }
            finishLookupDrag()
        }
#if os(iOS)
        .overlay {
            SplitterPanHandle(
                translationHandler: { translation in
                    applyLookupDrag(translation: translation, containerWidth: containerWidth)
                },
                endHandler: finishLookupDrag
            )
        }
#else
        .highPriorityGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    applyLookupDrag(translation: value.translation.width, containerWidth: containerWidth)
                }
                .onEnded { _ in
                    finishLookupDrag()
                }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
#endif
    }

    private var playbackChromeSpacing: CGFloat {
#if os(iOS)
        2
#else
        10
#endif
    }

    private var playbackChromeHorizontalPadding: CGFloat {
#if os(iOS)
        16
#else
        24
#endif
    }

    private var playbackChromeTopPadding: CGFloat {
#if os(iOS)
        4
#else
        14
#endif
    }

    private var playbackChromeBottomPadding: CGFloat {
#if os(iOS)
        6
#else
        14
#endif
    }

#if os(macOS)
    private var desktopExpandedPlaybackControls: some View {
        HStack(spacing: 18) {
            desktopTransportControls
            Divider().frame(height: 18)
            desktopReplayControls
            Spacer(minLength: 18)
            Text("Speed")
                .font(.system(size: 11))
                .foregroundStyle(Palette.dim)
            Slider(value: playbackSpeedBinding, in: 0.7...1.6, step: 0.05)
                .frame(width: 120)
            Text(String(format: "%.2fx", state.player.rate))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.dim)
                .frame(width: 44)
            desktopExpandedChapterNavigator
        }
        .fixedSize(horizontal: true, vertical: false)
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .font(.system(size: 16))
    }

    private var desktopCompactPlaybackControls: some View {
        HStack(spacing: 12) {
            desktopTransportControls
            Divider().frame(height: 18)
            desktopReplayControls
            Spacer(minLength: 8)
            desktopSpeedMenu
            desktopCompactChapterNavigator
        }
        .fixedSize(horizontal: true, vertical: false)
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .font(.system(size: 16))
    }

    private var desktopTransportControls: some View {
        HStack(spacing: 14) {
            Button { state.skipPlayback(seconds: -state.settings.skipSeconds) } label: {
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

            Button { state.skipPlayback(seconds: state.settings.skipSeconds) } label: {
                Image(systemName: "goforward.5")
            }
            .help("Forward \(Int(state.settings.skipSeconds))s")
        }
    }

    private var desktopReplayControls: some View {
        HStack(spacing: 10) {
            Button { state.replaySentence() } label: {
                Image(systemName: "repeat.1")
            }
            .help("Replay sentence")

            Toggle(isOn: sentenceLoopBinding) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Loop current sentence")
            .foregroundStyle(state.loopSentence ? Palette.gold : Palette.ink)

            Toggle(isOn: deepReadingBinding) {
                Image(systemName: "book.closed")
            }
            .toggleStyle(.button)
            .help("Deep Reading: pause after each sentence")
            .foregroundStyle(state.settings.deepReadingMode ? Palette.gold : Palette.ink)

            Button { state.continueDeepReading() } label: {
                Image(systemName: "forward.end.circle")
            }
            .help("Continue with the next sentence (⌘↩)")
            .disabled(!state.canContinueDeepReading)
            .accessibilityLabel("Continue with next sentence")
        }
    }

    private var desktopSpeedMenu: some View {
        Menu {
            Picker("Speed", selection: playbackSpeedBinding) {
                ForEach(PlaybackSpeedCatalog.values, id: \.self) { speed in
                    Text(String(format: "%.2fx", speed)).tag(speed)
                }
            }
        } label: {
            Label(String(format: "%.2fx", state.player.rate), systemImage: "speedometer")
                .lineLimit(1)
        }
        .help("Playback speed")
    }

    @ViewBuilder
    private var desktopExpandedChapterNavigator: some View {
        if let chapters = state.selectedBook?.chapters, chapters.count > 1 {
            Button { state.openPreviousChapter() } label: {
                Image(systemName: "chevron.left")
            }
            .help("Previous chapter")
            .accessibilityLabel("Previous chapter")
            .disabled(!state.canOpenPreviousChapter)

            Picker("Chapter", selection: chapterSelectionBinding(in: chapters)) {
                ForEach(chapters) { chapter in
                    Text(chapter.title).tag(chapter.id)
                }
            }
            .frame(width: 180)
            .help(state.selectedChapter?.title ?? "Choose a chapter")

            Button { state.openNextChapter() } label: {
                Image(systemName: "chevron.right")
            }
            .help("Next chapter")
            .accessibilityLabel("Next chapter")
            .disabled(!state.canOpenNextChapter)
        }
    }

    @ViewBuilder
    private var desktopCompactChapterNavigator: some View {
        if let chapters = state.selectedBook?.chapters, chapters.count > 1 {
            Menu {
                Picker("Chapter", selection: chapterSelectionBinding(in: chapters)) {
                    ForEach(chapters) { chapter in
                        Text(chapter.title).tag(chapter.id)
                    }
                }
            } label: {
                Label(chapterPositionLabel(in: chapters), systemImage: "list.bullet")
                    .lineLimit(1)
            }
            .help(state.selectedChapter?.title ?? "Choose a chapter")
        }
    }
#endif

    private var playbackSpeedBinding: Binding<Double> {
        Binding(
            get: { Double(state.player.rate) },
            set: { value in
                state.player.rate = Float(value)
                state.persistSettings()
            }
        )
    }

    private func chapterSelectionBinding(in chapters: [Chapter]) -> Binding<String> {
        Binding(
            get: { state.selectedChapterID ?? "" },
            set: { id in
                guard let book = state.selectedBook,
                      let chapter = chapters.first(where: { $0.id == id })
                else { return }
                state.open(chapter: chapter, in: book, autoplay: state.player.isPlaying)
            }
        )
    }

    private func chapterPositionLabel(in chapters: [Chapter]) -> String {
        let index = chapters.firstIndex { $0.id == state.selectedChapterID } ?? 0
        return "Chapter \(index + 1) of \(chapters.count)"
    }

#if os(iOS)
    private var iPadCompactPlaybackBar: some View {
        HStack(spacing: 4) {
            iPadTransportControls
            iPadReplayControls
            Spacer(minLength: 8)
            iPadSpeedMenu
            iPadChapterNavigator
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .font(.system(size: 17, weight: .regular))
        .frame(minHeight: 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback controls")
    }

    private var iPadTransportControls: some View {
        HStack(spacing: 2) {
            Button { state.skipPlayback(seconds: -state.settings.skipSeconds) } label: {
                Image(systemName: "gobackward.5")
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back \(Int(state.settings.skipSeconds)) seconds")

            Button { state.skipSentence(direction: -1) } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous sentence")

            Button { state.togglePlay() } label: {
                Image(systemName: state.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Palette.gold)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(state.player.isPlaying ? "Pause" : "Play")

            Button { state.skipSentence(direction: 1) } label: {
                Image(systemName: "forward.end.fill")
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next sentence")

            Button { state.skipPlayback(seconds: state.settings.skipSeconds) } label: {
                Image(systemName: "goforward.5")
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Forward \(Int(state.settings.skipSeconds)) seconds")
        }
    }

    private var iPadReplayControls: some View {
        HStack(spacing: 2) {
            Button { state.replaySentence() } label: {
                Image(systemName: "repeat.1")
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Replay sentence")

            Toggle(isOn: sentenceLoopBinding) {
                Image(systemName: "repeat")
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .toggleStyle(.button)
            .foregroundStyle(state.loopSentence ? Palette.gold : Palette.ink)
            .accessibilityLabel("Loop sentence")

            Toggle(isOn: deepReadingBinding) {
                Image(systemName: "book.closed")
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .toggleStyle(.button)
            .foregroundStyle(state.settings.deepReadingMode ? Palette.gold : Palette.ink)
            .accessibilityLabel("Deep Reading")
            .accessibilityValue(state.settings.deepReadingMode ? "On" : "Off")

            Button { state.continueDeepReading() } label: {
                Image(systemName: "forward.end.circle")
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(state.isDeepReadingPaused ? Palette.gold : Palette.ink)
            .disabled(!state.canContinueDeepReading)
            .accessibilityLabel("Continue with next sentence")
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    private var iPadSpeedMenu: some View {
        Button {
            showSpeedPicker.toggle()
        } label: {
            Text(String(format: "%.2f×", state.player.rate))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.gold)
                .frame(minHeight: 36)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            HStack(spacing: 0) {
                Button { state.openPreviousChapter() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .disabled(!state.canOpenPreviousChapter)
                .accessibilityLabel("Previous chapter")

                Menu {
                    Picker("Chapter", selection: chapterSelectionBinding(in: chapters)) {
                        ForEach(chapters) { chapter in
                            Text(chapter.title).tag(chapter.id)
                        }
                    }
                } label: {
                    Text(chapterCompactPositionLabel(in: chapters))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .frame(minHeight: 36)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .help(state.selectedChapter?.title ?? "Choose a chapter")
                .accessibilityLabel("Chapter")
                .accessibilityValue(chapterPositionLabel(in: chapters))

                Button { state.openNextChapter() } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .disabled(!state.canOpenNextChapter)
                .accessibilityLabel("Next chapter")
            }
        }
    }

    private func chapterCompactPositionLabel(in chapters: [Chapter]) -> String {
        let index = chapters.firstIndex { $0.id == state.selectedChapterID } ?? 0
        return "\(index + 1)/\(chapters.count)"
    }
#endif
}

#if os(iOS)
private struct SplitterPanHandle: UIViewRepresentable {
    var translationHandler: (CGFloat) -> Void
    var endHandler: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(translationHandler: translationHandler, endHandler: endHandler)
    }

    func makeUIView(context: Context) -> SplitterPanView {
        let view = SplitterPanView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: SplitterPanView, context: Context) {
        context.coordinator.translationHandler = translationHandler
        context.coordinator.endHandler = endHandler
        uiView.coordinator = context.coordinator
    }

    final class Coordinator {
        var translationHandler: (CGFloat) -> Void
        var endHandler: () -> Void

        init(translationHandler: @escaping (CGFloat) -> Void, endHandler: @escaping () -> Void) {
            self.translationHandler = translationHandler
            self.endHandler = endHandler
        }
    }
}

private final class SplitterPanView: UIView {
    var coordinator: SplitterPanHandle.Coordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -8, dy: 0).contains(point)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self).x
        switch gesture.state {
        case .began, .changed:
            coordinator?.translationHandler(translation)
        case .ended, .cancelled, .failed:
            coordinator?.endHandler()
        default:
            break
        }
    }
}

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

struct ChapterChatVoiceWaveform: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Palette.terracotta.opacity(0.45 + levels[index] * 0.55))
                    .frame(width: 2.5, height: max(3, levels[index] * 20))
            }
        }
        .frame(width: 106, height: 22, alignment: .leading)
        .animation(.easeOut(duration: 0.12), value: levels)
        .accessibilityHidden(true)
    }
}

private struct ChapterAssistantView: View {
    @Bindable var state: AppState
    @State private var chatDraft = ""
    @State private var dictation = ChapterChatDictation()
    @State private var voice = VoiceCaptureStatus()
    @State private var showChapterRetranslateConfirmation = false
    @State private var showChapterSummaryRegenerateConfirmation = false

    private var assistantBodySize: CGFloat {
        AssistantTypography.bodySize(forReaderScale: state.settings.readerFontScale)
    }

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
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.gold)
                }
                Spacer()
                Button {
                    dictation.cancel()
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

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            chapterTranslateMenu
                            chapterSummaryButton
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            chapterTranslateMenu
                            chapterSummaryButton
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                            .controlSize(.small)
                            .inspectorActionLabel()
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
                                .controlSize(.small)
                                .inspectorActionLabel()
                            }
                        }
                    }

                    if let summary = state.chapterSummary {
                        assistantCard(title: "Chapter summary") {
                            ChapterSummaryView(summary: summary.summary)
                            if summary.status == .pending {
                                Text("Draft saved locally · \(summary.model). Accept to keep it as this chapter's summary.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.gold)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 10) {
                                    Button("Accept") { state.acceptChapterSummary() }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Palette.terracotta)
                                    Button("Reject") { state.rejectChapterSummary() }
                                    Button("Regenerate") {
                                        showChapterSummaryRegenerateConfirmation = true
                                    }
                                }
                                .controlSize(.small)
                                .inspectorActionLabel()
                            } else if summary.status == .accepted {
                                HStack(spacing: 10) {
                                    Text("Saved · Model: \(summary.model)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.gold)
                                    Spacer(minLength: 0)
                                    Button("Regenerate") {
                                        showChapterSummaryRegenerateConfirmation = true
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    if let translation = state.chapterTranslation {
                        assistantCard(title: "Chapter translation") {
                            GlossBody(text: translation, size: assistantBodySize)
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
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(message.role == .user ? Palette.mute : Palette.gold)
                                if message.role == .user {
                                    Text(message.text)
                                        .font(.system(size: AssistantTypography.defaultBodySize))
                                        .foregroundStyle(Palette.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                } else {
                                    GlossBody(text: message.text, size: assistantBodySize)
                                }
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
                                .disabled(
                                    voice.isListening
                                        || voice.isRequestingPermission
                                        || voice.isFinalizing
                                )
                            ZStack {
                                if voice.isRequestingPermission || voice.isFinalizing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: voice.isListening ? "stop.circle.fill" : "mic.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(voice.isListening ? Palette.terracotta : Palette.gold)
                                }
                                PlatformTap(
                                    isEnabled: voice.canStart || voice.isListening,
                                    accessibilityLabelText: voice.isListening
                                        ? "Stop voice input"
                                        : (voice.isFinalizing ? "Finishing voice input" : "Start voice input"),
                                    accessibilityHintText: "Uses on-device speech recognition and leaves the result editable before sending.",
                                    action: toggleDictation
                                )
                            }
                            .frame(width: 28, height: 28)
                            Button(action: sendChat) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 22))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.gold)
                            .disabled(
                                voice.isListening
                                    || voice.isRequestingPermission
                                    || voice.isFinalizing
                                    || chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                        if voice.isListening {
                            HStack(spacing: 8) {
                                ChapterChatVoiceWaveform(levels: voice.audioLevels)
                                Text("Listening on device…")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Palette.terracotta)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Voice input is listening")
                        } else if let message = voice.preparationMessage {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.dim)
                        } else if let message = voice.unavailableMessage {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.dim)
                                .fixedSize(horizontal: false, vertical: true)
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
        .onDisappear { dictation.cancel() }
        .confirmationDialog(
            "Retranslate the whole chapter?",
            isPresented: $showChapterRetranslateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Retranslate whole chapter", role: .destructive) {
                state.translateChapter(mode: .retranslateAll)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the chapter's existing sentence translations with new drafts for review.")
        }
        .confirmationDialog(
            "Regenerate chapter summary?",
            isPresented: $showChapterSummaryRegenerateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Regenerate", role: .destructive) {
                state.summarizeChapter()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The new summary will be a draft. Rejecting it restores the currently saved summary.")
        }
    }

    private var chapterTranslateMenu: some View {
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
                showChapterRetranslateConfirmation = true
            }
        } label: {
            Label("Translate chapter", systemImage: "globe")
                .inspectorActionLabel()
                .frame(maxWidth: .infinity)
        }
    }

    private var chapterSummaryButton: some View {
        Button {
            if state.chapterSummary == nil {
                state.summarizeChapter()
            } else {
                showChapterSummaryRegenerateConfirmation = true
            }
        } label: {
            Label(
                state.chapterSummary == nil ? "Summarise" : "Regenerate summary",
                systemImage: "text.alignleft"
            )
            .inspectorActionLabel()
            .frame(maxWidth: .infinity)
        }
    }

    private func sendChat() {
        dictation.stop()
        let question = chatDraft
        chatDraft = ""
        state.sendChapterChat(question)
    }

    private func toggleDictation() {
        if voice.isListening {
            dictation.stop()
            return
        }
        state.player.pause()
        dictation.start(
            existingText: chatDraft,
            locale: VoiceCaptureLocale.speechLocale(
                for: .chapterQuestion,
                audiobook: state.currentAudiobookLanguage
            ),
            onStatus: { voice = $0 },
            onWillRecord: { state.player.pause() },
            onTextUpdate: { chatDraft = $0 }
        )
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
                .font(.headline)
                .foregroundStyle(Palette.ink)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct ChapterSummaryView: View {
    let summary: ChapterSummaryPresentation
    @ScaledMetric(relativeTo: .body) private var overviewSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(summary.overview)
                .font(.system(size: overviewSize, weight: .medium, design: .serif))
                .foregroundStyle(Palette.ink)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            summarySection(title: "Key points", items: summary.keyPoints)
            summarySection(title: "Characters & ideas", items: summary.charactersOrIdeas)

            if !summary.keyConcepts.isEmpty {
                sectionLabel("Key concepts")
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(summary.keyConcepts.enumerated()), id: \.offset) { _, concept in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(concept.name)
                                .font(.system(size: bodySize, weight: .semibold, design: .serif))
                                .foregroundStyle(Palette.ink)
                            Text(concept.explanation)
                                .font(.system(size: bodySize, design: .serif))
                                .foregroundStyle(Palette.dim)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            summarySection(title: "Themes", items: summary.themes)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func summarySection(title: String, items: [String]) -> some View {
        if !items.isEmpty {
            sectionLabel(title)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle()
                            .fill(Palette.gold)
                            .frame(width: 4, height: 4)
                        Text(item)
                            .font(.system(size: bodySize, design: .serif))
                            .foregroundStyle(Palette.ink)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: labelSize, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
            Rectangle()
                .fill(Palette.line)
                .frame(height: 1)
        }
        .foregroundStyle(Palette.gold)
    }
}

private struct PlaybackChrome: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Text(formatClock(state.player.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.dim)
                .frame(width: 54, alignment: .leading)
            Slider(
                value: Binding(
                    get: { state.player.currentTime },
                    set: { state.seekPlayback(to: $0) }
                ),
                in: 0...max(state.player.duration, 0.1)
            )
            .controlSize(.small)
            .tint(Palette.gold)
            Text(formatClock(state.player.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.dim)
                .frame(width: 54, alignment: .trailing)
        }
        .onChange(of: state.player.currentTime) { _, _ in
            state.tickPlaybackModes()
        }
    }
}

private struct TranscriptTextColumn: View {
    @Bindable var state: AppState
    @Binding var autoScroll: Bool
    @Binding var readerScrollTarget: ReaderScrollTarget?
    let proxyWidth: CGFloat
    let type: ReaderType

    var body: some View {
        let cursor = PlaybackCursor.resolve(
            segments: state.transcript?.segments ?? [],
            time: state.player.currentTime
        )
        let studyOverlayEnabled = state.settings.showStudyOverlay
        let studyLanguageKey = state.studyIndex.language
        let studyLearning = state.studyIndex.learning
        let studyKnown = state.studyIndex.known
        ScrollView {
            LazyVStack(alignment: .leading, spacing: type.paragraph) {
                if let transcript = state.transcript {
                    ForEach(transcript.segments) { segment in
                        SentenceRow(
                            segment: segment,
                            currentID: cursor.segmentID,
                            currentWordID: segment.id == cursor.segmentID ? cursor.wordID : nil,
                            focusedSegmentID: state.focusedSegmentID,
                            focusedWordID: state.focusedWordID,
                            textSource: state.textSource,
                            gloss: state.sentenceGloss(for: segment),
                            isTranslating: state.isLLMJobActive(kind: .sentenceTranslation, targetID: segment.id),
                            languageLabel: state.studyLanguage.menuLabel,
                            studyOverlayEnabled: studyOverlayEnabled,
                            studyLanguageKey: studyLanguageKey,
                            studyLearningLemmas: studyLearning,
                            studyKnownLemmas: studyKnown,
                            onSeek: { time in
                                state.focusedSegmentID = segment.id
                                state.focusedWordID = nil
                                state.seekToSentence(segment, time: time, autoplay: state.settings.playOnSelect)
                            },
                            onPlayFrom: { time in
                                state.focusedSegmentID = segment.id
                                state.seekToSentence(segment, time: time, autoplay: true)
                            },
                            onInspect: { word in
                                state.focusedSegmentID = segment.id
                                state.focusedWordID = word.id
                                state.inspect(word: word)
                            },
                            onSave: { word in state.addVocab(word: word, segment: segment) },
                            onMarkKnown: { word in
                                state.markKnown(word, known: !state.isMarkedKnown(word))
                            },
                            onTranslate: { state.translateCurrentSentence() },
                            onAccept: { if let g = state.sentenceGloss(for: segment) { state.acceptGloss(g) } },
                            onReject: { if let g = state.sentenceGloss(for: segment) { state.rejectGloss(g) } },
                            onRetry: { state.retranslateSentence(segment) },
                            type: type
                        )
                        .equatable()
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
        .onChange(of: cursor.segmentID) { _, _ in
            state.ensureAutoTranslation()
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
        guard let chapterID = state.selectedChapterID else { return nil }
        let cursor = PlaybackCursor.resolve(
            segments: state.transcript?.segments ?? [],
            time: state.player.currentTime
        )
        guard let segmentID = cursor.segmentID else { return nil }
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
            Text("This app transcribes the audio on this device so every spoken word can be highlighted. Ebooks rarely match audiobooks exactly — publisher intros, number wording, and abridgements all drift — so speech-to-text is the source of timing, then we align the ebook when it helps.")
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
    var studyOverlayEnabled = false
    var studyLanguageKey = ""
    var studyLearningLemmas: Set<StudyLemma> = []
    var studyKnownLemmas: Set<StudyLemma> = []
    let onSeek: (TimeInterval) -> Void
    let onPlayFrom: (TimeInterval) -> Void
    let onInspect: (TranscriptWord) -> Void
    let onSave: (TranscriptWord) -> Void
    var onMarkKnown: (TranscriptWord) -> Void = { _ in }
    let onTranslate: () -> Void
    let onAccept: () -> Void
    let onReject: () -> Void
    let onRetry: () -> Void
    let type: ReaderType
    @State private var showRetranslateConfirmation = false

    private var isCurrent: Bool { segment.id == currentID }
    private var isFocused: Bool { segment.id == focusedSegmentID }
    private var isSelected: Bool { isCurrent || isFocused }

    @ViewBuilder
    private func wordTokens(_ tokens: [TranscriptWord], dimmed: Bool) -> some View {
        FlowLayout(spacing: type.word, lineSpacing: type.line) {
            ForEach(tokens) { word in
                WordToken(
                    word: word,
                    isCurrent: word.id == currentWordID || word.id == focusedWordID,
                    dimmed: dimmed,
                    fontSize: type.body,
                    font: type.font,
                    bold: type.bold,
                    studyOverlayEnabled: studyOverlayEnabled,
                    familiarity: familiarity(of: word),
                    onSeek: UncheckedAction { onSeek(word.start) },
                    onPlayFrom: UncheckedAction { onPlayFrom(word.start) },
                    onInspect: UncheckedAction { onInspect(word) },
                    onSave: UncheckedAction { onSave(word) },
                    onMarkKnown: UncheckedAction { onMarkKnown(word) }
                )
            }
        }
    }

    private func familiarity(of word: TranscriptWord) -> WordFamiliarity {
        guard let lemma = StudyLemma.make(language: studyLanguageKey, surface: word.text) else {
            return .unknown
        }
        return WordFamiliarityResolver.status(
            lemma: lemma,
            learning: studyLearningLemmas,
            known: studyKnownLemmas
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(formatClock(segment.start))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected ? Palette.gold : Palette.mute)
                if let score = segment.alignmentScore, score >= 0.52 {
                    Text("ebook matched")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.mute)
                }
            }

            if textSource == .spoken || textSource == .dual {
                if isSelected || studyOverlayEnabled {
                    wordTokens(StudyTokenIndex.tokens(in: segment), dimmed: !isSelected)
                } else {
                    Text(segment.spokenText)
                        .font(type.font.font(size: type.body, bold: type.bold))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(type.line)
                }
            }

            if textSource == .original || textSource == .dual {
                let original = segment.trustedEbookText ?? (textSource == .original ? segment.spokenText : nil)
                if let original {
                    if textSource == .original, studyOverlayEnabled {
                        wordTokens(StudyTokenIndex.tokens(in: segment), dimmed: !isSelected)
                    } else {
                        Text(original)
                            .font(type.font.font(size: textSource == .dual ? type.dual : type.body, bold: type.bold))
                            .foregroundStyle(isSelected ? Palette.ink : Palette.dim)
                            .italic(textSource == .dual)
                            .lineSpacing(type.line)
                    }
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
            if isTranslating {
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
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.gold)
                        Button("Accept", action: onAccept)
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.terracotta)
                            .controlSize(.small)
                        Button("Reject", action: onReject)
                            .controlSize(.small)
                        Button("Retranslate") { showRetranslateConfirmation = true }
                            .controlSize(.small)
                    } else if gloss.status == .accepted {
                        Text("Saved · Model: \(gloss.model)")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.gold)
                        Button("Retranslate") { showRetranslateConfirmation = true }
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
        .confirmationDialog(
            "Retranslate this sentence?",
            isPresented: $showRetranslateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Retranslate", role: .destructive, action: onRetry)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current translation with a new draft for review.")
        }
    }
}

extension SentenceRow: Equatable {
    nonisolated static func == (lhs: SentenceRow, rhs: SentenceRow) -> Bool {
        lhs.segment == rhs.segment
            && lhs.currentID == rhs.currentID
            && lhs.currentWordID == rhs.currentWordID
            && lhs.focusedSegmentID == rhs.focusedSegmentID
            && lhs.focusedWordID == rhs.focusedWordID
            && lhs.textSource == rhs.textSource
            && lhs.gloss == rhs.gloss
            && lhs.isTranslating == rhs.isTranslating
            && lhs.studyOverlayEnabled == rhs.studyOverlayEnabled
            && lhs.studyLanguageKey == rhs.studyLanguageKey
            && lhs.studyLearningLemmas == rhs.studyLearningLemmas
            && lhs.studyKnownLemmas == rhs.studyKnownLemmas
            && lhs.type.body == rhs.type.body
            && lhs.type.word == rhs.type.word
            && lhs.type.line == rhs.type.line
            && lhs.type.font == rhs.type.font
            && lhs.type.bold == rhs.type.bold
    }
}

private struct WordToken: View {
    let word: TranscriptWord
    let isCurrent: Bool
    let dimmed: Bool
    var fontSize: CGFloat = 22
    var font: ReaderFontChoice = .newYork
    var bold = false
    var studyOverlayEnabled = false
    var familiarity: WordFamiliarity = .unknown
    let onSeek: UncheckedAction
    let onPlayFrom: UncheckedAction
    let onInspect: UncheckedAction
    let onSave: UncheckedAction
    var onMarkKnown = UncheckedAction()

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
            .overlay(alignment: .bottom) {
                if studyOverlayEnabled, familiarity != .known {
                    Rectangle()
                        .fill(Palette.terracotta)
                        .frame(height: familiarity == .learning ? 1 : 1.5)
                        .padding(.horizontal, isCurrent ? 4 : 0)
                        .opacity((familiarity == .learning ? 0.7 : 1) * (dimmed ? 0.55 : 1))
                }
            }
            .onTapGesture { onSeek(); onInspect() }
            .accessibilityValue(overlayAccessibilityValue)
            .contextMenu {
                Button("Play from here") { onPlayFrom() }
                Button("Look up") { onInspect() }
                Button("Add to vocabulary") { onSave() }
                Button("Mark known") { onMarkKnown() }
            }
    }

    private var overlayAccessibilityValue: String {
        guard studyOverlayEnabled else { return "" }
        switch familiarity {
        case .learning: return "learning"
        case .unknown: return "unknown"
        case .known: return ""
        }
    }
}

private struct WordInspector: View {
    @Bindable var state: AppState
    var type: ReaderType = .metrics(columnWidth: 420, scale: 1)
    @Environment(\.colorScheme) private var colorScheme
    @State private var webHeight: CGFloat = 180
    @State private var showRetranslateConfirmation = false

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
                                    .inspectorActionLabel()
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
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
                                    .inspectorActionLabel()
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.small)
#endif
                        }

                        inspectorCard(title: "In this sentence") {
                            if state.isLLMJobActive(kind: .wordTranslation, targetID: word.id) {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text("Asking \(state.selectedLLMModel)…")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.dim)
                                }
                                .padding(.vertical, 8)
                            } else if let gloss = state.selectedWordGloss {
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
                                        Button("Retranslate") { showRetranslateConfirmation = true }
                                    }
                                    .controlSize(.small)
                                    .inspectorActionLabel()
                                } else if gloss.status == .accepted {
                                    Text("Saved · Model: \(gloss.model)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.gold)
                                    Button("Retranslate") { showRetranslateConfirmation = true }
                                        .buttonStyle(.bordered)
                                }
                            } else {
                                Button {
                                    state.translateSelectedWord()
                                } label: {
                                    Label("Sentence meaning", systemImage: "globe")
                                        .inspectorActionLabel()
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityLabel("This-sentence meaning (\(state.selectedLLMModel))")
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
                            let isKnown = state.isMarkedKnown(word)
                            Button {
                                state.markKnown(word, known: !isKnown)
                            } label: {
                                Label(isKnown ? "Mark unknown" : "Mark known", systemImage: isKnown ? "eye.slash" : "eye")
                                    .inspectorActionLabel()
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel(isKnown ? "Mark \(word.text) unknown" : "Mark \(word.text) known")

                            Button {
                                state.addVocab(word: word, segment: seg)
                            } label: {
                                Label(isSaved ? "Already in vocabulary" : "Add to vocabulary", systemImage: isSaved ? "checkmark.circle.fill" : "bookmark")
                                    .inspectorActionLabel()
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.terracotta)
                            .controlSize(.small)
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
        .confirmationDialog(
            "Retranslate this word or phrase?",
            isPresented: $showRetranslateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Retranslate", role: .destructive) {
                state.retranslateSelectedWord()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current in-sentence meaning with a new draft for review.")
        }
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
    let size: CGFloat
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(presentation.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 8) {
                    if !section.title.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(section.title)
                                .font(.system(size: sectionLabelSize, weight: .semibold))
                                .textCase(.uppercase)
                                .tracking(0.5)
                            Rectangle()
                                .fill(Palette.line)
                                .frame(height: 1)
                        }
                        .foregroundStyle(Palette.gold)
                    }
                    sectionContent(section)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presentation: GlossPresentation {
        GlossPresentation.parse(text)
    }

    @ViewBuilder
    private func sectionContent(_ section: GlossPresentation.Section) -> some View {
        if !section.examples.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(section.examples.enumerated()), id: \.offset) { _, example in
                    ExampleRow(example: example, bodySize: bodySize)
                }
            }
            .padding(.leading, 10)
        } else if !section.notes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(section.notes.enumerated()), id: \.offset) { index, note in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(note.source)
                                .font(.system(size: bodySize, weight: .semibold, design: .serif))
                                .foregroundStyle(Palette.ink)
                            Text(note.category)
                                .font(.system(size: sectionLabelSize, weight: .semibold))
                                .foregroundStyle(Palette.terracotta)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Palette.goldSoft, in: Capsule())
                        }
                        Text(note.explanation)
                            .font(.system(size: bodySize, design: .serif))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
                    if index < section.notes.count - 1 {
                        Divider().overlay(Palette.line)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    paragraphRow(paragraph, index: index, section: section)
                }
            }
            .padding(.leading, section.kind == .sentenceMeaning ? 14 : 0)
            .overlay(alignment: .leading) {
                if section.kind == .sentenceMeaning {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Palette.line)
                        .frame(width: 2)
                }
            }
        }
    }

    @ViewBuilder
    private func paragraphRow(
        _ paragraph: GlossPresentation.Paragraph,
        index: Int,
        section: GlossPresentation.Section
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if paragraph.kind == .bullet {
                Text("•")
                    .foregroundStyle(Palette.gold)
            } else if paragraph.kind == .numbered {
                Text("\(index + 1).")
                    .foregroundStyle(Palette.mute)
            }
            formattedText(paragraph.text)
                .font(.system(
                    size: bodySize,
                    weight: section.kind == .translation ? .medium : .regular,
                    design: .serif
                ))
                .foregroundStyle(paragraphColor(for: section.kind))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var bodySize: CGFloat {
        AssistantTypography.clampedBodySize(size) * dynamicTypeScale
    }

    private var sectionLabelSize: CGFloat {
        AssistantTypography.minimumBodySize * dynamicTypeScale
    }

    private func formattedText(_ text: String) -> Text {
        guard let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return Text(text) }
        return Text(attributed)
    }

    private func paragraphColor(for kind: GlossPresentation.Section.Kind) -> Color {
        switch kind {
        case .translation, .sentenceMeaning, .other:
            Palette.ink
        case .learningNotes, .examples:
            .secondary
        }
    }
}

private struct ExampleRow: View {
    let example: GlossPresentation.Example
    let bodySize: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("•")
                .foregroundStyle(Palette.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(example.source)
                    .font(.system(size: bodySize, design: .serif))
                    .foregroundStyle(Palette.ink)
                if let translation = example.translation, !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: bodySize, design: .serif))
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}
