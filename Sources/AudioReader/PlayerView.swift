import SwiftUI
import AppKit

struct PlayerView: View {
    @Bindable var state: AppState
    @State private var autoScroll = true
    @State private var lookupWidth: CGFloat = 0
    @State private var lookupDragStart: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.line)
            if state.isTranscribing {
                transcribeBanner
            }
            if let err = state.errorMessage ?? state.translationError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
            }
            lyricPane
            controls
        }
        .background(Palette.bg)
        .onChange(of: state.player.currentTime) { _, _ in
            state.tickLoop()
        }
        .onChange(of: state.currentSegment?.id) { _, _ in
            state.ensureAutoTranslation()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let path = state.selectedBook?.coverPath, let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
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
            .frame(maxWidth: 220)
            .onChange(of: state.textSource) { _, _ in state.persistSettings() }

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

            HStack(spacing: 4) {
                Button {
                    state.settings.readerFontScale = max(0.75, (state.settings.readerFontScale * 10 - 1).rounded() / 10)
                    state.persistSettings()
                } label: {
                    Text("A").font(.system(size: 11, weight: .medium, design: .serif))
                }
                .help("Smaller text")
                Button {
                    state.settings.readerFontScale = min(1.6, (state.settings.readerFontScale * 10 + 1).rounded() / 10)
                    state.persistSettings()
                } label: {
                    Text("A").font(.system(size: 16, weight: .medium, design: .serif))
                }
                .help("Larger text")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.dim)

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
            let lookupOpen = state.selectedWord != nil
            let split = min(max(effectiveLookupWidth, 280), max(280, geo.size.width - 320))
            let textWidth = lookupOpen ? geo.size.width - split - 8 : geo.size.width
            let type = ReaderType.metrics(columnWidth: textWidth, scale: state.settings.readerFontScale)
            HStack(spacing: 0) {
                textColumn(proxyWidth: textWidth, type: type)
                    .frame(width: textWidth)
                if lookupOpen {
                    lookupSplitter(maxWidth: geo.size.width)
                    WordInspector(state: state, type: type)
                        .frame(width: split)
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
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    private func textColumn(proxyWidth: CGFloat, type: ReaderType) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: type.body * 0.75) {
                    if let transcript = state.transcript {
                        ForEach(transcript.segments) { segment in
                            SentenceRow(
                                segment: segment,
                                currentID: state.currentSegment?.id,
                                currentWordID: state.currentWord?.id,
                                focusedSegmentID: state.focusedSegmentID,
                                focusedWordID: state.focusedWordID,
                                textSource: state.textSource,
                                gloss: segment.id == state.currentSegment?.id ? state.currentSentenceGloss : nil,
                                isTranslating: state.isTranslating && segment.id == state.currentSegment?.id,
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
                                onAccept: { if let g = state.currentSentenceGloss { state.acceptGloss(g) } },
                                onReject: { if let g = state.currentSentenceGloss { state.rejectGloss(g) } },
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
                .padding(.horizontal, max(20, min(48, proxyWidth * 0.06)))
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.currentSegment?.id) { _, newID in
                guard autoScroll, let newID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
            .onChange(of: state.revealToken) { _, _ in
                guard let id = state.scrollSegmentID else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
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
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink)
            .font(.system(size: 16))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Palette.panel)
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
                    FlowLayout(spacing: 2, lineSpacing: type.line) {
                        ForEach(segment.words) { word in
                            WordToken(
                                word: word,
                                isCurrent: word.id == currentWordID || word.id == focusedWordID,
                                dimmed: false,
                                fontSize: type.body,
                                onSeek: { onSeek(word.start) },
                                onPlayFrom: { onPlayFrom(word.start) },
                                onInspect: { onInspect(word) },
                                onSave: { onSave(word) }
                            )
                        }
                    }
                } else {
                    Text(segment.spokenText)
                        .font(.system(size: type.body, design: .serif))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(type.line)
                }
            }

            if textSource == .original || textSource == .dual {
                let original = segment.ebookText ?? (textSource == .original ? segment.spokenText : nil)
                if let original {
                    Text(original)
                        .font(.system(size: textSource == .dual ? type.dual : type.body, design: .serif))
                        .foregroundStyle(isSelected ? Palette.ink : Palette.dim)
                        .italic(textSource == .dual)
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
                    Text("Grok is translating…")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.dim)
                }
            } else if let gloss {
                GlossBody(text: gloss.text, size: type.gloss)
                HStack(spacing: 8) {
                    if gloss.status == .pending {
                        Text("Draft · \(gloss.model)")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.gold)
                        Button("Accept", action: onAccept)
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.terracotta)
                            .controlSize(.small)
                        Button("Reject", action: onReject)
                            .controlSize(.small)
                    } else if gloss.status == .accepted {
                        Text("Saved in library")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.gold)
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
    let onSeek: () -> Void
    let onPlayFrom: () -> Void
    let onInspect: () -> Void
    let onSave: () -> Void

    var body: some View {
        Text(word.text)
            .font(.system(size: fontSize, weight: isCurrent ? .semibold : .regular, design: .serif))
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
                                    Text("Saved — this word will not be sent to Grok again.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.gold)
                                }
                            } else if state.isTranslating {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text("Asking \(state.settings.grokModel)…")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.dim)
                                }
                                .padding(.vertical, 8)
                            } else {
                                Button {
                                    state.translateSelectedWord()
                                } label: {
                                    Label("This-sentence meaning (\(state.settings.grokModel))", systemImage: "globe")
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
                            Button {
                                state.addVocab(word: word, segment: seg)
                            } label: {
                                Label("Add to vocabulary", systemImage: "bookmark")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Palette.terracotta)
                            .controlSize(.large)
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
