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

#if os(iOS)
private enum ReaderAuxiliarySheet: Identifiable {
    case lookup
    case chapterAI

    var id: Self { self }
}
#endif

struct PlayerView: View {
    @Bindable var state: AppState
    @State private var autoScroll = true
    @State private var readerScrollTarget: ReaderScrollTarget?
    @State private var editingTranscriptSegment: TranscriptSegment?
    @State private var readerProgressError: String?
    @State private var correctionPreviewTask: Task<Void, Never>?
    @State private var showsBookNavigation = false
#if os(iOS)
    @State private var showSpeedPicker = false
    @State private var showReplaceEbookImporter = false
#endif

    var body: some View {
        VStack(spacing: 0) {
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
            if state.readerProgressChoices.count > 1 {
                readerProgressConflictBanner
            }
            if !state.transcriptOverlayConflictStates.isEmpty {
                transcriptOverlayConflictBanner
            }
            lyricPane
            if state.selectedChapter?.hasAudio == true {
                VStack(spacing: playbackChromeSpacing) {
                    if let segment = state.currentSegment {
                        if state.isDeepReadingPaused {
                            ListenFirstCoachView(state: state, segment: segment)
                        } else if state.isReadAndPausePaused {
                            ReadAndPauseCoachView(state: state)
                        }
                    }
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
        }
        .background(Palette.bg)
        .navigationTitle(readerNavigationTitle)
#if os(macOS)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                desktopCompactHeaderControls
            }
        }
        .inspector(isPresented: inspectorPresentationBinding) {
            Group {
                if state.showChapterAssistant {
                    ChapterAssistantView(state: state)
                } else {
                    WordInspector(
                        state: state,
                        type: .metrics(
                            columnWidth: effectiveLookupWidth,
                            scale: state.settings.readerFontScale,
                            lineSpacing: state.settings.readerLineSpacing,
                            wordSpacing: state.settings.readerWordSpacing,
                            font: state.settings.readerFont,
                            bold: state.settings.readerBold
                        )
                    )
                }
            }
            .inspectorColumnWidth(min: 300, ideal: effectiveLookupWidth, max: 540)
        }
#endif
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
        .sheet(item: iPadAuxiliarySheetBinding) { destination in
            Group {
                switch destination {
                case .lookup:
                    WordInspector(state: state, type: iPadAuxiliaryReaderType)
                case .chapterAI:
                    ChapterAssistantView(state: state)
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationSizing(.form)
        }
#endif
        .sheet(item: $state.shadowingSegment) { segment in
            ShadowingPracticeView(state: state, segment: segment)
        }
        .sheet(item: $state.chapterQuizSession) { _ in
            ChapterQuizView(state: state)
        }
        .sheet(isPresented: $showsBookNavigation) {
            EbookNavigationSheet(state: state)
        }
        .sheet(item: $editingTranscriptSegment) { segment in
            TranscriptCorrectionSheet(
                segment: segment,
                hasStoredCorrection: state.transcriptOverlay(for: segment.id) != nil,
                conflictChoices: state.transcriptOverlayChoices(for: segment.id),
                deviceName: state.syncDeviceName,
                onPreview: previewTranscriptCorrection,
                onSave: { text, start, end in
                    try state.saveTranscriptCorrection(
                        segmentID: segment.id,
                        text: text,
                        start: start,
                        end: end
                    )
                },
                onRestore: {
                    try state.restoreTranscriptCorrection(segmentID: segment.id)
                },
                onResolveConflict: { candidateID in
                    try state.resolveTranscriptOverlayConflict(
                        segmentID: segment.id,
                        choosing: candidateID
                    )
                }
            )
        }
        .alert("Reader update failed", isPresented: Binding(
            get: { readerProgressError != nil },
            set: {
                if !$0 { readerProgressError = nil }
            }
        )) {
            Button("OK", role: .cancel) {
                readerProgressError = nil
            }
        } message: {
            Text(readerProgressError ?? "The reader could not be updated.")
        }
        .onDisappear {
            correctionPreviewTask?.cancel()
        }
    }

    private var readerProgressConflictBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Choose where to continue", systemImage: "arrow.triangle.branch")
                .font(.headline)
            Text("Reading moved on more than one device. Pick the position you want to keep.")
                .font(.subheadline)
                .foregroundStyle(Palette.dim)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { readerProgressChoiceButtons }
                VStack(alignment: .leading, spacing: 8) { readerProgressChoiceButtons }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.goldSoft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.progressConflict")
    }

    @ViewBuilder
    private var readerProgressChoiceButtons: some View {
        ForEach(state.readerProgressChoices) { choice in
            Button {
                resolveReaderProgress(choice.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(readerProgressChapterTitle(choice.chapterID.rawValue))
                        .font(.subheadline.weight(.semibold))
                    Text("\(formatClock(choice.relativeSeconds)) · \(state.syncDeviceName(choice.deviceID)) · \(choice.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(Palette.dim)
                }
                .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("reader.progressChoice.\(choice.id)")
        }
    }

    private var transcriptOverlayConflictBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Choose a transcript correction", systemImage: "text.badge.checkmark")
                .font(.headline)
            Text("The same sentence was corrected differently on another device. Compare the versions before sync continues.")
                .font(.subheadline)
                .foregroundStyle(Palette.dim)
            ForEach(state.transcriptOverlayConflictStates.keys.sorted(), id: \.self) { segmentID in
                if let segment = state.presentedTranscript?.segments.first(where: { $0.id == segmentID }) {
                    Button {
                        editingTranscriptSegment = segment
                    } label: {
                        let choices = state.transcriptOverlayChoices(for: segmentID)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choices.map { "“\($0.overlay.correctedText)”" }.joined(separator: " or "))
                                .lineLimit(2)
                            Text(choices.map { state.syncDeviceName($0.overlay.provenance.deviceID) }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(Palette.dim)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens both corrections with their timing and device")
                    .accessibilityIdentifier("transcript.conflictReview.\(segmentID)")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.goldSoft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript.conflictBanner")
    }

    private func readerProgressChapterTitle(_ chapterID: String) -> String {
        state.selectedBook?.chapters.first(where: { $0.id == chapterID })?.title ?? "Saved position"
    }

    private func resolveReaderProgress(_ candidateID: String) {
        do {
            try state.resolveReaderProgress(choosing: candidateID)
        } catch {
            readerProgressError = error.localizedDescription
        }
    }

    private func previewTranscriptCorrection(start: TimeInterval, end: TimeInterval) {
        correctionPreviewTask?.cancel()
        state.seekPlayback(to: start)
        if !state.player.isPlaying { state.player.play() }
        correctionPreviewTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(max(0.25, end - start)))
            } catch {
                return
            }
            if state.player.currentTime >= start, state.player.currentTime <= end + 0.5 {
                state.player.pause()
            }
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
    private var desktopCompactHeaderControls: some View {
        HStack(spacing: 10) {
            textSourcePicker
                .labelsHidden()
                .frame(width: 220)
            Spacer(minLength: 0)
            bookNavigationButton
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

            if state.selectedChapter?.hasAudio == true {
                Button {
                    state.transcribeSelected(force: state.transcript != nil)
                } label: {
                    Image(systemName: "waveform")
                }
                .disabled(state.isTranscribing)
                .accessibilityLabel(state.transcript == nil ? "Transcribe" : "Re-transcribe")
                .help(state.transcript == nil ? "Transcribe chapter" : "Re-transcribe chapter")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
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

    private var readAndPauseBinding: Binding<Bool> {
        Binding(
            get: { state.settings.readAndPauseMode },
            set: { state.setReadAndPauseMode($0) }
        )
    }

    private var readerNavigationTitle: String {
        ReaderWindowTitle.make(
            book: state.selectedBook?.title,
            chapter: state.selectedChapter?.title,
            coverage: state.chapterCoverage
        )
    }

    private var bookNavigationButton: some View {
        Button {
            if let bookID = state.selectedBookID {
                state.account.recordUsage(
                    name: "reading.book_navigation_opened",
                    properties: ["bookId": bookID]
                )
            }
            showsBookNavigation = true
        } label: {
            Image(systemName: "list.bullet")
        }
        .disabled(state.selectedBook?.ebookPath == nil)
        .accessibilityLabel("Contents and search")
        .accessibilityIdentifier("reader.bookNavigation")
        .help("Contents and Search Book")
    }

#if os(iOS)
    @ToolbarContentBuilder
    private var iPadReaderToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            bookNavigationButton
        }
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
        if state.selectedChapter?.hasAudio == true {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.transcribeSelected(force: state.transcript != nil)
                } label: {
                    Image(systemName: "waveform")
                }
                .disabled(state.isTranscribing)
                .accessibilityLabel(state.transcript == nil ? "Transcribe" : "Re-transcribe")
                .help(state.transcript == nil ? "Transcribe chapter" : "Re-transcribe chapter")
            }
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
            case .managedQwen:
                Text(state.account.mode.isSignedIn ? "Managed Qwen · server policy" : "Sign in to use Managed Qwen")
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
            Toggle("Listen First", isOn: deepReadingBinding)
                .accessibilityHint("Hides unfinished and future sentences, then pauses and reveals each completed sentence.")
                .accessibilityLabel("Listen First")
            Toggle("Read & Pause", isOn: readAndPauseBinding)
                .accessibilityHint("Keeps every sentence visible and pauses after each one.")
                .accessibilityLabel("Read and Pause")
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
        state.account.recordUsage(
            name: "llm.provider_changed",
            properties: ["provider": connection.rawValue]
        )
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

#if os(macOS)
    private var effectiveLookupWidth: CGFloat {
        CGFloat(state.settings.lookupPanelWidth)
    }

    private var inspectorPresentationBinding: Binding<Bool> {
        Binding(
            get: { state.selectedWord != nil || state.showChapterAssistant },
            set: { presented in
                guard !presented else { return }
                state.showChapterAssistant = false
                state.selectedWord = nil
                state.selectedWordSegmentID = nil
                state.selectedWordContextText = nil
                state.definition = nil
                state.dictionaryHits = []
            }
        )
    }
#endif

#if os(iOS)
    private var iPadAuxiliarySheetBinding: Binding<ReaderAuxiliarySheet?> {
        Binding(
            get: {
                if state.showChapterAssistant { return .chapterAI }
                if state.selectedWord != nil { return .lookup }
                return nil
            },
            set: { destination in
                guard destination == nil else { return }
                state.showChapterAssistant = false
                state.selectedWord = nil
                state.selectedWordSegmentID = nil
                state.selectedWordContextText = nil
                state.definition = nil
                state.dictionaryHits = []
            }
        )
    }

    private var iPadAuxiliaryReaderType: ReaderType {
        .metrics(
            columnWidth: 520,
            scale: state.settings.readerFontScale,
            lineSpacing: state.settings.readerLineSpacing,
            wordSpacing: state.settings.readerWordSpacing,
            font: state.settings.readerFont,
            bold: state.settings.readerBold
        )
    }
#endif

    private var lyricPane: some View {
        GeometryReader { geo in
            let type = ReaderType.metrics(
                columnWidth: geo.size.width,
                scale: state.settings.readerFontScale,
                lineSpacing: state.settings.readerLineSpacing,
                wordSpacing: state.settings.readerWordSpacing,
                font: state.settings.readerFont,
                bold: state.settings.readerBold
            )
            TranscriptTextColumn(
                state: state,
                autoScroll: $autoScroll,
                readerScrollTarget: $readerScrollTarget,
                proxyWidth: geo.size.width,
                type: type,
                onEditSegment: { editingTranscriptSegment = $0 }
            )
        }
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
            .accessibilityLabel(state.player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("reader.playback.toggle")

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

            readingPaceMenu

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

    private var readingPaceMenu: some View {
        Menu {
            Button {
                state.setDeepReadingMode(false)
                state.setReadAndPauseMode(false)
            } label: {
                Label("Continuous", systemImage: !state.settings.deepReadingMode && !state.settings.readAndPauseMode ? "checkmark" : "play")
            }
            Button {
                state.setDeepReadingMode(true)
            } label: {
                Label("Listen First", systemImage: state.settings.deepReadingMode ? "checkmark" : "ear")
            }
            Button {
                state.setReadAndPauseMode(true)
            } label: {
                Label("Read & Pause", systemImage: state.settings.readAndPauseMode ? "checkmark" : "text.alignleft")
            }
        } label: {
            Image(systemName: state.settings.deepReadingMode ? "ear" : (state.settings.readAndPauseMode ? "text.alignleft" : "play"))
#if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
#endif
        }
        .foregroundStyle(state.settings.deepReadingMode || state.settings.readAndPauseMode ? Palette.gold : Palette.ink)
        .help("Choose continuous, Listen First, or Read & Pause playback")
        .accessibilityLabel("Reading pace")
        .accessibilityValue(state.settings.deepReadingMode ? "Listen First" : (state.settings.readAndPauseMode ? "Read and Pause" : "Continuous"))
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
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback controls")
    }

    private var iPadTransportControls: some View {
        HStack(spacing: 2) {
            Button { state.skipPlayback(seconds: -state.settings.skipSeconds) } label: {
                Image(systemName: "gobackward.5")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back \(Int(state.settings.skipSeconds)) seconds")

            Button { state.skipSentence(direction: -1) } label: {
                Image(systemName: "backward.end.fill")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous sentence")

            Button { state.togglePlay() } label: {
                Image(systemName: state.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Palette.gold)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(state.player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("reader.playback.toggle")

            Button { state.skipSentence(direction: 1) } label: {
                Image(systemName: "forward.end.fill")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next sentence")

            Button { state.skipPlayback(seconds: state.settings.skipSeconds) } label: {
                Image(systemName: "goforward.5")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Forward \(Int(state.settings.skipSeconds)) seconds")
        }
    }

    private var iPadReplayControls: some View {
        HStack(spacing: 2) {
            Button { state.replaySentence() } label: {
                Image(systemName: "repeat.1")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Replay sentence")

            Toggle(isOn: sentenceLoopBinding) {
                Image(systemName: "repeat")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .toggleStyle(.button)
            .foregroundStyle(state.loopSentence ? Palette.gold : Palette.ink)
            .accessibilityLabel("Loop sentence")

            readingPaceMenu

            Button { state.continueDeepReading() } label: {
                Image(systemName: "forward.end.circle")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(state.isDeepReadingPaused || state.isReadAndPausePaused ? Palette.gold : Palette.ink)
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
                .frame(minHeight: 44)
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
                        .frame(minWidth: 44, minHeight: 44)
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
                        .frame(minHeight: 44)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .help(state.selectedChapter?.title ?? "Choose a chapter")
                .accessibilityLabel("Chapter")
                .accessibilityValue(chapterPositionLabel(in: chapters))

                Button { state.openNextChapter() } label: {
                    Image(systemName: "chevron.right")
                        .frame(minWidth: 44, minHeight: 44)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.uiTestReduceMotion) private var uiTestReduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Palette.terracotta.opacity(0.45 + levels[index] * 0.55))
                    .frame(width: 2.5, height: max(3, levels[index] * 20))
            }
        }
        .frame(width: 106, height: 22, alignment: .leading)
        .animation(reduceMotion || uiTestReduceMotion ? nil : .easeOut(duration: 0.12), value: levels)
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
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                    Text(state.selectedLLMModel)
                        .font(.system(size: 11))
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
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Chapter AI")
                .accessibilityIdentifier("reader.chapterAI.close")
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

                    if let job = state.selectedChapterSummaryJob {
                        assistantCard(title: job.stage) {
                            if !job.state.isTerminal {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(job.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Chapter summary progress")
                        .accessibilityValue("\(job.stage). \(job.detail)")
                    }

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

                    if state.isChapterAssistantWorking,
                       !state.isLLMJobActive(kind: .chapterSummary) {
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
                    if summary.status == .pending || summary.status == .edited || summary.status == .replaced {
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
                            .frame(width: 44, height: 44)
                            Button(action: sendChat) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 22))
                                    .frame(width: 44, height: 44)
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
                state.summarizeChapter(force: true)
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
            Rectangle()
                .fill(Palette.line)
                .frame(height: 1)
        }
        .foregroundStyle(Palette.gold)
    }
}

private struct EbookNavigationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: AppState
    @State private var document: EPUBDocument?
    @State private var query = ""
    @State private var searchResults: [EPUBSearchResult] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Palette.dim)
                            .accessibilityHidden(true)
                        TextField("Search Book", text: $query)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Search Book")
                            .accessibilityIdentifier("reader.bookSearch")
                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Palette.dim)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear book search")
                        }
                    }
                }
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView("Reading contents…")
                        Spacer()
                    }
                } else if let loadError {
                    ContentUnavailableView(
                        "Contents Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if let document {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        contents(document)
                    } else if searchResults.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        searchMatches(searchResults)
                    }
                }
            }
            .navigationTitle(query.isEmpty ? "Contents" : "Search Book")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 480)
        .accessibilityIdentifier("reader.bookNavigation.sheet")
        .task(id: state.selectedBook?.ebookPath) {
            await loadDocument()
        }
        .task(id: searchTaskID) {
            await updateSearchResults()
        }
    }

    private var searchTaskID: String {
        "\(document?.sections.count ?? -1)|\(query)"
    }

    @ViewBuilder
    private func contents(_ document: EPUBDocument) -> some View {
        Section("Contents") {
            ForEach(document.sections.indices, id: \.self) { index in
                let section = document.sections[index]
                Button {
                    open(sectionIndex: index, matching: nil)
                } label: {
                    HStack {
                        Text(section.title)
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        if state.selectedChapter?.ebookSectionIndex == index {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Palette.gold)
                                .accessibilityLabel("Current chapter")
                        }
                    }
                    .padding(.leading, CGFloat(section.navigationLevel) * 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(state.selectedChapter?.ebookSectionIndex == index ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func searchMatches(_ results: [EPUBSearchResult]) -> some View {
        Section("Search Results") {
            ForEach(results) { result in
                Button {
                    open(sectionIndex: result.sectionIndex, matching: query)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.sectionTitle)
                            .font(.headline)
                            .foregroundStyle(Palette.ink)
                        Text(result.snippet)
                            .font(.subheadline)
                            .foregroundStyle(Palette.dim)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(result.sectionTitle). \(result.snippet)")
            }
        }
    }

    private func loadDocument() async {
        guard let path = state.selectedBook?.ebookPath else {
            document = nil
            isLoading = false
            loadError = "This book does not have an EPUB file."
            return
        }
        isLoading = true
        loadError = nil
        let parsed = await Task.detached(priority: .userInitiated) {
            EPUBParser.document(from: path)
        }.value
        guard !Task.isCancelled, state.selectedBook?.ebookPath == path else { return }
        document = parsed
        isLoading = false
        if parsed == nil { loadError = "The EPUB could not be read." }
    }

    private func updateSearchResults() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let document else {
            searchResults = []
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }
        let results = await Task.detached(priority: .userInitiated) {
            EPUBParser.search(trimmed, in: document)
        }.value
        guard !Task.isCancelled,
              query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        else { return }
        searchResults = results
    }

    private func open(sectionIndex: Int, matching query: String?) {
        guard let book = state.selectedBook,
              state.openEbookSection(at: sectionIndex, in: book, matching: query)
        else { return }
        if query != nil {
            state.account.recordUsage(
                name: "reading.book_search_result_opened",
                properties: ["bookId": book.id, "sectionIndex": "\(sectionIndex)"]
            )
        }
        dismiss()
    }
}

private struct EPUBReaderCoverPage: View {
    let book: Book

    var body: some View {
        VStack(spacing: 18) {
            Group {
                if let path = book.coverPath,
                   let image = CoverImageCache.shared.image(for: path) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Palette.panel2)
                        .overlay {
                            Image(systemName: "book.closed")
                                .font(.system(size: 52, weight: .light))
                                .foregroundStyle(Palette.gold)
                        }
                }
            }
            .frame(maxWidth: 320)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .compositingGroup()
            .clipShape(.rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 6)

            VStack(spacing: 5) {
                Text(book.title)
                    .font(.system(.title, design: .serif, weight: .semibold))
                    .multilineTextAlignment(.center)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(Palette.dim)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cover of \(book.title)" + (book.author.map { ", by \($0)" } ?? ""))
        .accessibilityIdentifier("reader.epubCover")
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
    }
}

private struct TranscriptTextColumn: View {
    @Bindable var state: AppState
    @Binding var autoScroll: Bool
    @Binding var readerScrollTarget: ReaderScrollTarget?
    let proxyWidth: CGFloat
    let type: ReaderType
    let onEditSegment: (TranscriptSegment) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.uiTestReduceMotion) private var uiTestReduceMotion

    var body: some View {
        let cursor = PlaybackCursor.resolve(
            segments: state.presentedTranscript?.segments ?? [],
            time: state.player.currentTime
        )
        let studyOverlayEnabled = state.settings.showStudyOverlay
        let studyLanguageKey = state.studyIndex.language
        let studyLearning = state.studyIndex.learning
        let studyKnown = state.studyIndex.known
        let orderedSegmentIDs = state.presentedTranscript?.segments.map(\.id) ?? []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: type.paragraph) {
                if let book = state.selectedBook,
                   state.selectedChapter?.ebookSectionIndex == 0 {
                    EPUBReaderCoverPage(book: book)
                }
                if let transcript = state.presentedTranscript {
                    ForEach(transcript.segments) { segment in
                        let listenFirstVisibility = state.settings.deepReadingMode
                            ? ListenFirstVisibility.resolve(
                                segmentID: segment.id,
                                orderedSegmentIDs: orderedSegmentIDs,
                                currentSegmentID: cursor.segmentID,
                                pausedSegmentID: state.deepReadingPausedSentenceID,
                                replayRevealedSegmentID: state.listenFirstReplayRevealedSegmentID
                            )
                            : .revealed
                        SentenceRow(
                            segment: segment,
                            currentID: cursor.segmentID,
                            currentWordID: segment.id == cursor.segmentID ? cursor.wordID : nil,
                            focusedSegmentID: state.focusedSegmentID,
                            lookupWordID: state.selectedWord?.id,
                            textSource: state.readerTextSource,
                            gloss: state.sentenceGloss(for: segment),
                            isTranslating: state.isLLMJobActive(kind: .sentenceTranslation, targetID: segment.id),
                            languageLabel: state.studyLanguage.menuLabel,
                            studyOverlayEnabled: studyOverlayEnabled,
                            studyLanguageKey: studyLanguageKey,
                            studyLearningLemmas: studyLearning,
                            studyKnownLemmas: studyKnown,
                            onSeek: { time in
                                state.selectPlaybackAnchor(
                                    sentence: segment,
                                    word: nil,
                                    time: time,
                                    startPlayback: state.settings.playOnSelect
                                )
                            },
                            onPlayFrom: { time in
                                state.selectPlaybackAnchor(
                                    sentence: segment,
                                    word: nil,
                                    time: time,
                                    startPlayback: true
                                )
                            },
                            onInspect: { word in
                                state.selectPlaybackAnchor(
                                    sentence: segment,
                                    word: word,
                                    time: word.start,
                                    startPlayback: state.settings.playOnSelect
                                )
                            },
                            onSave: { word in state.addVocab(word: word, segment: segment) },
                            onMarkKnown: { word in
                                state.markKnown(word, known: !state.isMarkedKnown(word))
                            },
                            hasStoredCorrection: state.transcriptOverlay(for: segment.id) != nil,
                            listenFirstVisibility: listenFirstVisibility,
                            onReveal: { state.revealListenFirstSentence(segment.id) },
                            onEdit: { onEditSegment(segment) },
                            onTranslate: { state.translateSentence(segment) },
                            onAccept: { if let g = state.sentenceGloss(for: segment) { state.acceptGloss(g) } },
                            onReject: { if let g = state.sentenceGloss(for: segment) { state.rejectGloss(g) } },
                            onEditTranslation: { text in
                                if let gloss = state.sentenceGloss(for: segment) {
                                    state.editGloss(gloss, text: text)
                                }
                            },
                            onRetry: { state.retranslateSentence(segment) },
                            type: type
                        )
                        .equatable()
                        .id(segment.id)
                    }
                    if state.canLoadMoreTranscriptSegments {
                        Button("Load next \(Persistence.transcriptPageSize) segments") {
                            state.loadMoreTranscriptSegments()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("reader.loadMoreSegments")
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
                withAnimation(reduceMotion || uiTestReduceMotion ? nil : .easeOut(duration: 0.2)) {
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
                withAnimation(reduceMotion || uiTestReduceMotion ? nil : .easeOut(duration: 0.2)) {
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
            segments: state.presentedTranscript?.segments ?? [],
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

struct SentenceTranslationPresentation: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case draft(model: String)
        case saved(model: String)
    }

    struct Actions: OptionSet, Sendable {
        let rawValue: UInt8

        static let translate = Actions(rawValue: 1 << 0)
        static let accept = Actions(rawValue: 1 << 1)
        static let reject = Actions(rawValue: 1 << 2)
        static let edit = Actions(rawValue: 1 << 3)
        static let retranslate = Actions(rawValue: 1 << 4)
    }

    let showsBlock: Bool
    let showsSpinner: Bool
    let glossText: String?
    let status: Status?
    let actions: Actions

    /// Listen First is a hard boundary: hidden sentences cannot disclose assistant output or activity.
    static func resolve(
        isRevealed: Bool,
        isSelected: Bool,
        isTranslating: Bool,
        gloss: GlossEntry?
    ) -> SentenceTranslationPresentation {
        guard isRevealed else {
            return SentenceTranslationPresentation(
                showsBlock: false,
                showsSpinner: false,
                glossText: nil,
                status: nil,
                actions: []
            )
        }

        let status: Status?
        switch gloss?.status {
        case .pending, .edited, .replaced:
            status = gloss.map { .draft(model: $0.model) }
        case .accepted:
            status = gloss.map { .saved(model: $0.model) }
        case .rejected, .stale, nil:
            status = nil
        }

        let actions: Actions
        if !isSelected || isTranslating {
            actions = []
        } else {
            switch gloss?.status {
            case .pending, .edited, .replaced:
                actions = [.accept, .reject, .edit, .retranslate]
            case .accepted:
                actions = [.edit, .retranslate]
            case .rejected, .stale:
                actions = []
            case nil:
                actions = [.translate]
            }
        }

        return SentenceTranslationPresentation(
            showsBlock: isTranslating || gloss != nil || isSelected,
            showsSpinner: isTranslating,
            glossText: gloss?.text,
            status: status,
            actions: actions
        )
    }
}

private struct SentenceRow: View {
    let segment: TranscriptSegment
    let currentID: String?
    let currentWordID: String?
    let focusedSegmentID: String?
    let lookupWordID: String?
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
    let hasStoredCorrection: Bool
    let listenFirstVisibility: ListenFirstVisibility
    let onReveal: () -> Void
    let onEdit: () -> Void
    let onTranslate: () -> Void
    let onAccept: () -> Void
    let onReject: () -> Void
    let onEditTranslation: (String) -> Void
    let onRetry: () -> Void
    let type: ReaderType
    @State private var showRetranslateConfirmation = false
    @State private var showTranslationEditor = false
    @State private var editedTranslation = ""

    private var isCurrent: Bool { segment.id == currentID }
    private var isFocused: Bool { segment.id == focusedSegmentID }
    private var isSelected: Bool { isCurrent || isFocused }

    @ViewBuilder
    private func wordTokens(_ tokens: [TranscriptWord], dimmed: Bool) -> some View {
        FlowLayout(spacing: type.word, lineSpacing: type.line) {
            ForEach(tokens) { word in
                WordToken(
                    word: word,
                    isPlaybackCurrent: word.id == currentWordID,
                    isLookupFocused: word.id == lookupWordID,
                    dimmed: dimmed,
                    fontSize: type.body,
                    font: type.font,
                    bold: type.bold,
                    studyOverlayEnabled: studyOverlayEnabled,
                    familiarity: familiarity(of: word),
                    onPlayFrom: MainActorAction { onPlayFrom(word.start) },
                    onInspect: MainActorAction { onInspect(word) },
                    onSave: MainActorAction { onSave(word) },
                    onMarkKnown: MainActorAction { onMarkKnown(word) }
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
        let translationPresentation = SentenceTranslationPresentation.resolve(
            isRevealed: listenFirstVisibility == .revealed,
            isSelected: isSelected,
            isTranslating: isTranslating,
            gloss: gloss
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { onSeek(segment.start) } label: {
                    Text(formatClock(segment.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isSelected ? Palette.gold : Palette.dim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Seek to sentence at \(formatClock(segment.start))")
                .accessibilityIdentifier("reader.sentence.\(segment.id)")
                if let score = segment.alignmentScore, score >= 0.52 {
                    Text("ebook matched")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.dim)
                }
                if isSelected {
                    Button {
                        onEdit()
                    } label: {
                        Label(hasStoredCorrection ? "Edit correction" : "Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("transcript.edit")
                    .accessibilityHint("Edit this sentence's text and timing.")
                }
            }

            if listenFirstVisibility == .revealed {
                if textSource == .spoken || textSource == .dual {
                    if isSelected || studyOverlayEnabled {
                        wordTokens(StudyTokenIndex.tokens(in: segment), dimmed: !isSelected)
                    } else {
                        Button { onSeek(segment.start) } label: {
                            Text(segment.spokenText)
                                .font(type.font.font(size: type.body, bold: type.bold))
                                .foregroundStyle(Palette.dim)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(type.line)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if textSource == .original || textSource == .dual {
                    let original = segment.trustedEbookText ?? (textSource == .original ? segment.spokenText : nil)
                    if let original {
                        if textSource == .original, isSelected || studyOverlayEnabled {
                            wordTokens(
                                StudyTokenIndex.tokens(in: segment, source: .original),
                                dimmed: !isSelected
                            )
                        } else {
                            Button { onSeek(segment.start) } label: {
                                Text(original)
                                    .font(type.font.font(size: textSource == .dual ? type.dual : type.body, bold: type.bold))
                                    .foregroundStyle(isSelected ? Palette.ink : Palette.dim)
                                    .italic(textSource == .dual)
                                    .lineSpacing(type.line)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if translationPresentation.showsBlock {
                    translationBlock(translationPresentation)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: listenFirstVisibility == .currentHidden ? "ear" : "text.redaction")
                        .foregroundStyle(Palette.gold)
                    Text(listenFirstVisibility == .currentHidden
                         ? "Listen before revealing this sentence."
                         : "Future sentence hidden in Listen First.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.dim)
                    Spacer()
                    if listenFirstVisibility == .currentHidden {
                        Button("Reveal sentence", action: onReveal)
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("reader.listenFirstReveal")
                    }
                }
                .accessibilityElement(children: .contain)
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
        .opacity(isSelected ? 1 : 0.88)
        .accessibilityAction(named: "Play from sentence") { onPlayFrom(segment.start) }
        .accessibilityAction(named: "Seek to sentence") { onSeek(segment.start) }
    }

    private func translationBlock(_ presentation: SentenceTranslationPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if presentation.showsSpinner {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("The LLM is translating…")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.dim)
                }
            }
            if let status = presentation.status {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        translationStatus(status, fixed: true)
                        expandedTranslationActions(presentation)
                            .controlSize(.small)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        translationStatus(status, fixed: false)
                        compactTranslationActions(presentation)
                    }
                }
            } else if presentation.actions.contains(.translate) {
                Button(action: onTranslate) {
                    Label("Translate into \(languageLabel)", systemImage: "globe")
                }
                .controlSize(.small)
            }
            if let glossText = presentation.glossText {
                GlossBody(text: glossText, size: type.gloss)
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
        .sheet(isPresented: $showTranslationEditor) {
            AssistantResultEditSheet(text: $editedTranslation) {
                onEditTranslation(editedTranslation)
                showTranslationEditor = false
            }
        }
    }

    private func translationStatus(
        _ status: SentenceTranslationPresentation.Status,
        fixed: Bool
    ) -> some View {
        let text: String
        switch status {
        case .draft(let model): text = "Draft · Model: \(model)"
        case .saved(let model): text = "Saved · Model: \(model)"
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(Palette.gold)
            .lineLimit(fixed ? 1 : 2)
            .fixedSize(horizontal: fixed, vertical: false)
    }

    @ViewBuilder
    private func expandedTranslationActions(_ presentation: SentenceTranslationPresentation) -> some View {
        if presentation.actions.contains(.accept) {
            Button("Accept", action: onAccept)
                .buttonStyle(.borderedProminent)
                .tint(Palette.terracotta)
                .accessibilityIdentifier("reader.translation.accept")
        }
        if presentation.actions.contains(.reject) {
            Button("Reject", action: onReject)
                .accessibilityIdentifier("reader.translation.reject")
        }
        if presentation.actions.contains(.edit) {
            Button("Edit") { beginEditingTranslation(presentation) }
                .accessibilityIdentifier("reader.translation.edit")
        }
        if presentation.actions.contains(.retranslate) {
            Button("Retranslate") { showRetranslateConfirmation = true }
                .accessibilityIdentifier("reader.translation.retranslate")
        }
    }

    @ViewBuilder
    private func compactTranslationActions(_ presentation: SentenceTranslationPresentation) -> some View {
        if !presentation.actions.isEmpty {
            HStack(spacing: 8) {
                if presentation.actions.contains(.accept) {
                    Button("Accept", action: onAccept)
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.terracotta)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("reader.translation.accept")
                }
                if presentation.actions.contains(.reject) {
                    Button("Reject", role: .destructive, action: onReject)
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("reader.translation.reject")
                }
                if presentation.actions.contains(.edit) {
                    Button("Edit") { beginEditingTranslation(presentation) }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("reader.translation.edit")
                }
                if presentation.actions.contains(.retranslate) {
                    Button("Retranslate") { showRetranslateConfirmation = true }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("reader.translation.retranslate")
                }
            }
            .controlSize(.small)
        }
    }

    private func beginEditingTranslation(_ presentation: SentenceTranslationPresentation) {
        editedTranslation = presentation.glossText ?? ""
        showTranslationEditor = true
    }
}

/// Shared editor keeps macOS and iPad lifecycle semantics identical: saving creates an edited draft.
private struct AssistantResultEditSheet: View {
    @Binding var text: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit assistant result")
                .font(.headline)
            TextEditor(text: $text)
                .frame(minHeight: 180)
                .accessibilityIdentifier("assistantResult.editText")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save draft", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("assistantResult.saveEdit")
            }
        }
        .padding(24)
        .frame(minWidth: 360, idealWidth: 520, minHeight: 280)
    }
}

private struct TranscriptCorrectionSheet: View {
    let segment: TranscriptSegment
    let hasStoredCorrection: Bool
    let conflictChoices: [StoredTranscriptOverlayCandidate]
    let deviceName: (String) -> String
    let onPreview: (TimeInterval, TimeInterval) -> Void
    let onSave: (String, TimeInterval, TimeInterval) throws -> Void
    let onRestore: () throws -> Void
    let onResolveConflict: (String) throws -> Void
    @State private var correctedText: String
    @State private var correctedStart: TimeInterval
    @State private var correctedEnd: TimeInterval
    @State private var validationError: String?
    @Environment(\.dismiss) private var dismiss

    init(
        segment: TranscriptSegment,
        hasStoredCorrection: Bool,
        conflictChoices: [StoredTranscriptOverlayCandidate],
        deviceName: @escaping (String) -> String,
        onPreview: @escaping (TimeInterval, TimeInterval) -> Void,
        onSave: @escaping (String, TimeInterval, TimeInterval) throws -> Void,
        onRestore: @escaping () throws -> Void,
        onResolveConflict: @escaping (String) throws -> Void
    ) {
        self.segment = segment
        self.hasStoredCorrection = hasStoredCorrection
        self.conflictChoices = conflictChoices
        self.deviceName = deviceName
        self.onPreview = onPreview
        self.onSave = onSave
        self.onRestore = onRestore
        self.onResolveConflict = onResolveConflict
        _correctedText = State(initialValue: segment.spokenText)
        _correctedStart = State(initialValue: segment.start)
        _correctedEnd = State(initialValue: segment.end)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Corrected sentence") {
                    TextEditor(text: $correctedText)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("transcript.text")
                }
                Section("Timing") {
                    LabeledContent("Start") {
                        TextField(
                            "Start",
                            value: $correctedStart,
                            format: .number.precision(.fractionLength(2))
                        )
                        .multilineTextAlignment(.trailing)
#if os(iOS)
                        .keyboardType(.decimalPad)
#endif
                        .accessibilityIdentifier("transcript.start")
                    }
                    LabeledContent("End") {
                        TextField(
                            "End",
                            value: $correctedEnd,
                            format: .number.precision(.fractionLength(2))
                        )
                        .multilineTextAlignment(.trailing)
#if os(iOS)
                        .keyboardType(.decimalPad)
#endif
                        .accessibilityIdentifier("transcript.end")
                    }
                    Text("Sentence timing must remain inside the chapter, last at least 0.25 seconds, and not overlap its neighbors.")
                        .font(.caption)
                        .foregroundStyle(Palette.dim)
                }
                if let validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.terracotta)
                    }
                }
                if conflictChoices.count > 1 {
                    Section("Choose correction") {
                        Text("This sentence was corrected on more than one device. Choose the version to keep.")
                            .font(.caption)
                            .foregroundStyle(Palette.dim)
                        ForEach(conflictChoices) { candidate in
                            Button {
                                do {
                                    try onResolveConflict(candidate.id)
                                    dismiss()
                                } catch {
                                    validationError = error.localizedDescription
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.overlay.correctedText)
                                        .lineLimit(2)
                                    Text("\(formatClock(candidate.overlay.correctedStart))–\(formatClock(candidate.overlay.correctedEnd)) · \(deviceName(candidate.overlay.provenance.deviceID)) · \(candidate.overlay.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(Palette.dim)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .accessibilityIdentifier("transcript.conflictChoice.\(candidate.id)")
                        }
                    }
                    .accessibilityIdentifier("transcript.conflict")
                }
                if hasStoredCorrection {
                    Section {
                        Button("Restore Original", role: .destructive) {
                            do {
                                try onRestore()
                                dismiss()
                            } catch {
                                validationError = error.localizedDescription
                            }
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("transcript.restore")
                    }
                }
            }
            .navigationTitle("Edit sentence")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
#if os(iOS)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        onPreview(correctedStart, correctedEnd)
                    } label: {
                        Label("Preview", systemImage: "play.fill")
                    }
                    .disabled(!hasValidDraft)
                    .accessibilityIdentifier("transcript.preview")

                    Button("Save") {
                        saveCorrection()
                    }
                    .disabled(!hasValidDraft)
                    .accessibilityIdentifier("transcript.save")
                }
#else
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 8) {
                        Button {
                            onPreview(correctedStart, correctedEnd)
                        } label: {
                            Label("Preview", systemImage: "play.fill")
                        }
                        .disabled(!hasValidDraft)
                        .accessibilityIdentifier("transcript.preview")

                        Button("Save") {
                            saveCorrection()
                        }
                        .disabled(!hasValidDraft)
                        .accessibilityIdentifier("transcript.save")
                    }
                }
#endif
            }
        }
#if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
#endif
    }

    private var trimmedText: String {
        correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasValidDraft: Bool {
        !trimmedText.isEmpty && correctedStart >= 0 && correctedEnd - correctedStart >= 0.25
    }

    private func saveCorrection() {
        do {
            try onSave(trimmedText, correctedStart, correctedEnd)
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

extension SentenceRow: Equatable {
    nonisolated static func == (lhs: SentenceRow, rhs: SentenceRow) -> Bool {
        lhs.segment == rhs.segment
            && lhs.currentID == rhs.currentID
            && lhs.currentWordID == rhs.currentWordID
            && lhs.focusedSegmentID == rhs.focusedSegmentID
            && lhs.lookupWordID == rhs.lookupWordID
            && lhs.textSource == rhs.textSource
            && lhs.gloss == rhs.gloss
            && lhs.isTranslating == rhs.isTranslating
            && lhs.languageLabel == rhs.languageLabel
            && lhs.studyOverlayEnabled == rhs.studyOverlayEnabled
            && lhs.studyLanguageKey == rhs.studyLanguageKey
            && lhs.studyLearningLemmas == rhs.studyLearningLemmas
            && lhs.studyKnownLemmas == rhs.studyKnownLemmas
            && lhs.hasStoredCorrection == rhs.hasStoredCorrection
            && lhs.listenFirstVisibility == rhs.listenFirstVisibility
            && lhs.type.body == rhs.type.body
            && lhs.type.word == rhs.type.word
            && lhs.type.line == rhs.type.line
            && lhs.type.font == rhs.type.font
            && lhs.type.bold == rhs.type.bold
    }
}

private struct WordToken: View {
    let word: TranscriptWord
    let isPlaybackCurrent: Bool
    let isLookupFocused: Bool
    let dimmed: Bool
    var fontSize: CGFloat = 22
    var font: ReaderFontChoice = .newYork
    var bold = false
    var studyOverlayEnabled = false
    var familiarity: WordFamiliarity = .unknown
    let onPlayFrom: MainActorAction
    let onInspect: MainActorAction
    let onSave: MainActorAction
    var onMarkKnown = MainActorAction()

    var body: some View {
        Button {
            onInspect()
        } label: {
            Text(word.text)
                .font(font.font(size: fontSize, bold: bold || isPlaybackCurrent || isLookupFocused))
                .foregroundStyle(isPlaybackCurrent ? Palette.inkOnGold : (dimmed ? Palette.dim : Palette.ink))
                .padding(.horizontal, isPlaybackCurrent || isLookupFocused ? 4 : 0)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isPlaybackCurrent ? Palette.gold : (isLookupFocused ? Palette.terracotta.opacity(0.14) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isLookupFocused ? Palette.terracotta : Color.clear, lineWidth: 1.5)
                )
                .overlay(alignment: .bottom) {
                    if studyOverlayEnabled, familiarity != .known {
                        Rectangle()
                            .fill(Palette.terracotta)
                            .frame(height: familiarity == .learning ? 1 : 1.5)
                            .padding(.horizontal, isPlaybackCurrent || isLookupFocused ? 4 : 0)
                            .opacity((familiarity == .learning ? 0.7 : 1) * (dimmed ? 0.7 : 1))
                    }
                }
        }
        .buttonStyle(.plain)
#if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
#endif
        .accessibilityLabel(word.text.trimmingCharacters(in: .whitespacesAndNewlines))
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("reader.word.\(word.id)")
        .accessibilityAction(named: "Play from here") { onPlayFrom() }
        .accessibilityAction(named: "Look up") { onInspect() }
        .accessibilityAction(named: "Add to vocabulary") { onSave() }
        .accessibilityAction(named: "Mark known") { onMarkKnown() }
        .contextMenu {
            Button("Play from here") { onPlayFrom() }
            Button("Look up") { onInspect() }
            Button("Add to vocabulary") { onSave() }
            Button("Mark known") { onMarkKnown() }
        }
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if isPlaybackCurrent { values.append("current audio word") }
        if isLookupFocused { values.append("selected for lookup") }
        if !overlayAccessibilityValue.isEmpty { values.append(overlayAccessibilityValue) }
        return values.joined(separator: ", ")
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

private enum WordInspectorSection {
    case dictionary
    case learning
}

private struct WordInspector: View {
    @Bindable var state: AppState
    var type: ReaderType = .metrics(columnWidth: 420, scale: 1)
    @Environment(\.colorScheme) private var colorScheme
    @State private var webHeight: CGFloat = 180
    @State private var showRetranslateConfirmation = false
    @State private var showTranslationEditor = false
    @State private var editedTranslation = ""
    @State private var selectedSection: WordInspectorSection = .dictionary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Lookup")
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Button {
                    state.selectedWord = nil
                    state.selectedWordSegmentID = nil
                    state.selectedWordContextText = nil
                    state.definition = nil
                    state.dictionaryHits = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.dim)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close Lookup")
                .accessibilityIdentifier("reader.lookup.close")
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

#if os(iOS)
                        Picker("Lookup section", selection: $selectedSection) {
                            Text("Dictionary").tag(WordInspectorSection.dictionary)
                            Text("Learning").tag(WordInspectorSection.learning)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("reader.lookup.tabs")
#endif

                        if showsDictionaryContent {
                            inspectorCard(title: "Apple Dictionary") {
#if os(iOS)
                                if DictionaryLookup.hasSystemDefinition(word.text) {
                                    Text("Open Apple Dictionary for its full entry. iPadOS does not expose Apple Dictionary text to other apps; return here and choose Learning for sentence meaning and vocabulary actions.")
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
                                    Label("Open Apple Dictionary", systemImage: "book")
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
                        }

                        if showsLearningContent {
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
                                    if gloss.status == .pending || gloss.status == .edited || gloss.status == .replaced {
                                        Text("Draft from \(gloss.model). Accept to keep it in the library.")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Palette.gold)
                                            .fixedSize(horizontal: false, vertical: true)
                                        HStack(spacing: 10) {
                                            Button("Accept") { state.acceptGloss(gloss) }
                                                .buttonStyle(.borderedProminent)
                                                .tint(Palette.terracotta)
                                            Button("Reject") { state.rejectGloss(gloss) }
                                            Button("Edit") {
                                                editedTranslation = gloss.text
                                                showTranslationEditor = true
                                            }
                                            Button("Retranslate") { showRetranslateConfirmation = true }
                                        }
                                        .controlSize(.small)
                                        .inspectorActionLabel()
                                    } else if gloss.status == .accepted {
                                        Text("Saved · Model: \(gloss.model)")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Palette.gold)
                                        HStack(spacing: 10) {
                                            Button("Edit") {
                                                editedTranslation = gloss.text
                                                showTranslationEditor = true
                                            }
                                            .buttonStyle(.bordered)
                                            Button("Retranslate") { showRetranslateConfirmation = true }
                                                .buttonStyle(.bordered)
                                        }
                                        .controlSize(.small)
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
                                    .accessibilityIdentifier("reader.lookup.meaning")
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
#if os(iOS)
                                    state.addVocabAndRequestMeaning(word: word, segment: seg)
#else
                                    state.addVocab(word: word, segment: seg)
#endif
                                } label: {
                                    Label(
                                        addVocabularyTitle(isSaved: isSaved),
                                        systemImage: isSaved ? "checkmark.circle.fill" : "bookmark"
                                    )
                                        .inspectorActionLabel()
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Palette.terracotta)
                                .controlSize(.small)
                                .disabled(isSaved)
                            }
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
        .sheet(isPresented: $showTranslationEditor) {
            AssistantResultEditSheet(text: $editedTranslation) {
                if let gloss = state.selectedWordGloss {
                    state.editGloss(gloss, text: editedTranslation)
                }
                showTranslationEditor = false
            }
        }
    }

    private var contextSegment: TranscriptSegment? {
        state.selectedWordContextSegment
    }

    // Apple Dictionary must remain separately presented on iPad because its controller cannot be safely embedded.
    private var showsDictionaryContent: Bool {
#if os(iOS)
        selectedSection == .dictionary
#else
        true
#endif
    }

    private var showsLearningContent: Bool {
#if os(iOS)
        selectedSection == .learning
#else
        true
#endif
    }

    private func addVocabularyTitle(isSaved: Bool) -> String {
        if isSaved { return "Already in vocabulary" }
#if os(iOS)
        return state.selectedWordGloss == nil ? "Add & get meaning" : "Add to vocabulary"
#else
        return "Add to vocabulary"
#endif
    }

    private func inspectorCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
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
