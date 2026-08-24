import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var draft: AppSettings
    @State private var xAIKey: String
    @State private var qwenKey: String
    @State private var saveFeedback: SaveFeedback?

    private let labelWidth: CGFloat = 156

    init(state: AppState) {
        self.state = state
        _draft = State(initialValue: state.settings)
        _xAIKey = State(initialValue: state.apiKeyDraft)
        _qwenKey = State(initialValue: state.qwenAPIKeyDraft)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Reader, dictionary, and language-model preferences")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.dim)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider().overlay(Palette.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    appearanceSection
#if os(macOS)
                    dictionarySection
#endif
                    languageSection
                    providerSection
                }
                .padding(24)
            }

            Divider().overlay(Palette.line)

            VStack(alignment: .leading, spacing: 8) {
                if let saveFeedback {
                    Label(saveFeedback.message, systemImage: saveFeedback.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(saveFeedback.succeeded ? Palette.gold : Color.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Text(AppVersion.displayName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                    Spacer()
                    Button("Cancel") { state.showSettings = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Save Settings", action: save)
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.terracotta)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Palette.panel)
        }
        .frame(width: settingsWidth, height: settingsHeight)
        .background(Palette.bg)
    }

    private var settingsWidth: CGFloat? {
#if os(macOS)
        700
#else
        nil
#endif
    }

    private var settingsHeight: CGFloat? {
#if os(macOS)
        700
#else
        nil
#endif
    }

    private var appearanceSection: some View {
        GroupBox("Appearance") {
            VStack(alignment: .leading, spacing: 12) {
                settingRow("Theme") {
                    Picker("Theme", selection: $draft.appearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.menuLabel).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                settingRow("Text size") {
                    HStack(spacing: 12) {
                        Slider(value: $draft.readerFontScale, in: 0.75...1.6, step: 0.05)
                        Text(String(format: "%.0f%%", draft.readerFontScale * 100))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                settingRow("Typeface") {
                    Picker("Typeface", selection: $draft.readerFont) {
                        ForEach(ReaderFontChoice.allCases) { font in
                            Text(font.rawValue).tag(font.rawValue)
                        }
                    }
                    .labelsHidden()
                    Toggle("Bold", isOn: $draft.readerBold)
                }
                settingRow("Line spacing") {
                    HStack(spacing: 12) {
                        Slider(value: $draft.readerLineSpacing, in: 0.7...2.0, step: 0.1)
                        Text(String(format: "%.1fx", draft.readerLineSpacing))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                settingRow("Word spacing") {
                    HStack(spacing: 12) {
                        Slider(value: $draft.readerWordSpacing, in: 0...12, step: 1)
                        Text("\(Int(draft.readerWordSpacing)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                settingRow("Margins") {
                    HStack(spacing: 12) {
                        Slider(value: $draft.readerMargin, in: 16...96, step: 4)
                        Text("\(Int(draft.readerMargin)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                helper("These reading controls are shared by the macOS and iPad readers.")
            }
            .padding(12)
        }
    }

    private var dictionarySection: some View {
        GroupBox("Apple Dictionary") {
            VStack(alignment: .leading, spacing: 12) {
#if os(iOS)
                helper("Word definitions use the dictionaries installed in iPadOS. Use Look Up in the reader to view all available entries.")
#else
                settingRow("Preferred dictionary") {
                    Picker("Preferred dictionary", selection: $draft.preferredDictionary) {
                        ForEach(DictionaryLookup.installedNames(), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                }
                helper("Changing Translate into automatically selects a matching installed dictionary when available. English definitions are used as the fallback.")
                HStack {
                    Spacer().frame(width: labelWidth + 16)
                    Button("Open Dictionary.app") { DictionaryLookup.openDictionaryApp() }
                }
#endif
            }
            .padding(12)
        }
    }

    private var languageSection: some View {
        GroupBox("Study language") {
            VStack(alignment: .leading, spacing: 12) {
                settingRow("Translate into") {
                    Picker("Translate into", selection: $draft.targetLanguage) {
                        ForEach(StudyLanguage.allCases) { language in
                            Text(language.menuLabel).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: draft.targetLanguage) { _, rawLanguage in
                        guard let language = StudyLanguage(rawValue: rawLanguage),
                              let name = DictionaryLookup.recommendedName(
                                language: language,
                                installedNames: DictionaryLookup.installedNames()
                              )
                        else { return }
                        draft.preferredDictionary = name
                    }
                }
                settingRow("Auto-translate") {
                    Toggle("Translate the current sentence with the selected LLM", isOn: $draft.autoTranslate)
                }
                settingRow("Play on selection") {
                    Toggle("Play audio when tapping a sentence or word", isOn: $draft.playOnSelect)
                }
                settingRow("Sentence context") {
                    countStepper(value: $draft.sentenceContextCount, range: 0...10, suffix: "before and after")
                }
                settingRow("Chapter block") {
                    countStepper(value: $draft.chapterTranslationBlockSize, range: 1...20, suffix: "sentences per request")
                }
                settingRow("Chat context") {
                    countStepper(value: $draft.chatContextCount, range: 0...20, suffix: "before and after")
                }
            }
            .padding(12)
        }
    }

    private var providerSection: some View {
        GroupBox("LLM provider") {
            VStack(alignment: .leading, spacing: 12) {
                settingRow("Provider") {
                    Picker("Provider", selection: $draft.llmProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.menuLabel).tag(provider.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                Divider().overlay(Palette.line)

                if draftProvider == .grok {
                    grokSettings
                } else {
                    qwenSettings
                }
            }
            .padding(12)
        }
    }

    private var grokSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            helper("A Grok Build session from `grok login` works without a console API key. A saved key overrides no environment variables.")
            settingRow("Connection") {
                Text(APIKeyStore.sourceLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(APIKeyStore.isConfigured ? Palette.gold : Palette.dim)
            }
            settingRow("xAI API key") {
                SecureField("Optional XAI_API_KEY", text: $xAIKey)
                    .textFieldStyle(.roundedBorder)
            }
            settingRow("Model") {
                Picker("Model", selection: $draft.grokModel) {
                    ForEach(GrokModel.allCases) { model in
                        Text(model.menuLabel).tag(model.rawValue)
                    }
                }
                .labelsHidden()
            }
            if GrokModel(rawValue: draft.grokModel)?.supportsEffort == true {
                settingRow("Reasoning effort") {
                    Picker("Reasoning effort", selection: $draft.grokEffort) {
                        ForEach(GrokEffort.allCases) { effort in
                            Text(effort.menuLabel).tag(effort.rawValue)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private var qwenSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            helper("QwenCloud uses Responses with a required JSON-schema tool for Qwen chapter translation, and JSON Chat Completions for supported third-party models. Thinking can improve complex answers but adds latency and token usage.")
            settingRow("Connection") {
                Text(QwenAPIKeyStore.sourceLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(QwenAPIKeyStore.isConfigured ? Palette.gold : Palette.dim)
            }
            settingRow("DashScope API key") {
                SecureField("DASHSCOPE_API_KEY", text: $qwenKey)
                    .textFieldStyle(.roundedBorder)
            }
            settingRow("Endpoint") {
                TextField("QwenCloud endpoint", text: $draft.qwenEndpoint)
                    .textFieldStyle(.roundedBorder)
            }
            settingRow("Text model") {
                Picker("Text model", selection: $draft.qwenModel) {
                    ForEach(qwenTextModels) { model in
                        Text(model.menuLabel).tag(model.id)
                    }
                }
                .labelsHidden()
                .onChange(of: draft.qwenModel) { _, _ in normalizeDraftQwenEffort() }
            }
            if let selected = qwenTextModels.first(where: { $0.id == draft.qwenModel }) {
                alignedHelper(selected.capabilities)
            }
            if QwenRequestPolicy.supportsThinkingToggle(model: draft.qwenModel) {
                settingRow("Thinking") {
                    Toggle("Enable thinking", isOn: $draft.qwenThinking)
                }
            }
            if !draftQwenEfforts.isEmpty
                && (!QwenRequestPolicy.supportsThinkingToggle(model: draft.qwenModel) || draft.qwenThinking) {
                settingRow("Reasoning effort") {
                    Picker("Reasoning effort", selection: $draft.qwenEffort) {
                        ForEach(draftQwenEfforts) { effort in
                            Text(effort.menuLabel).tag(effort.rawValue)
                        }
                    }
                    .labelsHidden()
                }
            }
            alignedHelper("QwenCloud Responses exposes none, minimal, low, medium, high, xhigh, and max. If a model or plan rejects an effort, AudioReader retries with that model's documented Chat mapping.", muted: true)
            if state.isLoadingQwenModels {
                HStack(spacing: 8) {
                    Spacer().frame(width: labelWidth + 16)
                    ProgressView().controlSize(.small)
                    Text("Refreshing the QwenCloud model list…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                }
            } else if let message = state.qwenModelsMessage {
                alignedHelper(message)
            }
            HStack {
                Spacer().frame(width: labelWidth + 16)
                Button {
                    Task {
                        if let models = await state.retrieveQwenModels(baseURL: draft.qwenEndpoint, apiKey: qwenKey) {
                            let selectable = models.filter(\.supportsText)
                            if !selectable.contains(where: { $0.id == draft.qwenModel }),
                               let replacement = selectable.first(where: { $0.id == "qwen3.8-max" }) ?? selectable.first {
                                draft.qwenModel = replacement.id
                            }
                        }
                    }
                } label: {
                    Label("Retrieve Models Again", systemImage: "arrow.clockwise")
                }
                .disabled(state.isLoadingQwenModels)
            }
            alignedHelper("\(state.qwenModels.count) catalog models. Only text-generation models appear in this picker.", muted: true)
        }
    }

    private var draftProvider: LLMProvider {
        LLMProvider(rawValue: draft.llmProvider) ?? .grok
    }

    private var qwenTextModels: [LLMModelInfo] {
        var models = state.qwenModels.filter(\.supportsText)
        if !models.contains(where: { $0.id == draft.qwenModel }) {
            models.append(.init(id: draft.qwenModel, brand: "Custom", capabilities: "Custom model ID", supportsText: true))
        }
        return models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private var draftQwenEfforts: [QwenEffort] {
        QwenRequestPolicy.supportedEfforts(model: draft.qwenModel)
    }

    private func normalizeDraftQwenEffort() {
        guard !draftQwenEfforts.isEmpty,
              !draftQwenEfforts.contains(where: { $0.rawValue == draft.qwenEffort })
        else { return }
        draft.qwenEffort = draftQwenEfforts.contains(.none) ? QwenEffort.none.rawValue : draftQwenEfforts[0].rawValue
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: labelWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func helper(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func alignedHelper(_ text: String, muted: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Spacer().frame(width: labelWidth)
            Text(text)
                .font(.system(size: muted ? 10 : 11))
                .foregroundStyle(muted ? Palette.mute : Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func countStepper(value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        HStack {
            Text("\(value.wrappedValue) \(suffix)")
                .foregroundStyle(Palette.dim)
            Spacer()
            Stepper("", value: value, in: range)
                .labelsHidden()
        }
    }

    private func save() {
        let settingsSaved = Persistence.saveSettings(draft)
        let xAIKeySaved = APIKeyStore.save(xAIKey)
        let qwenKeySaved = QwenAPIKeyStore.save(qwenKey)

        guard settingsSaved else {
            saveFeedback = .init(message: "Settings could not be written to disk. Your changes were not applied.", succeeded: false)
            return
        }

        state.settings = draft
        state.selectedDictionaryName = draft.preferredDictionary
        state.apiKeyDraft = xAIKey
        state.qwenAPIKeyDraft = qwenKey

        if xAIKeySaved && qwenKeySaved {
            saveFeedback = .init(message: "Settings saved successfully.", succeeded: true)
        } else {
            saveFeedback = .init(message: "Settings saved, but one or more API keys could not be stored.", succeeded: false)
        }

        guard draftProvider == .qwenCloud, qwenKeySaved else { return }
        Task {
            await state.refreshQwenModels()
            draft.qwenModel = state.settings.qwenModel
        }
    }
}

private struct SaveFeedback {
    let message: String
    let succeeded: Bool
}
