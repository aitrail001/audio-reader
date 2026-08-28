import Foundation
import SwiftUI

// THESIS: Settings is a first-class destination beside Library and Words, not a modal interruption of reading.
// OWN-WORLD: Paper-and-terracotta Palette, native grouped Form, system text styles, SF Symbols status.
// STORY: Open Settings like any other page, scan Account through LLM, save, return to the book.
// FIRST VIEWPORT: Large title, Account at top, Save in the trailing toolbar, version as the last row.
// FORM: Native grouped settings page (user-locked). FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance.

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var draft: AppSettings
    @State private var xAIKey: String
    @State private var qwenKey: String
    @State private var openAIKey: String
    @State private var removeXAIKey = false
    @State private var removeQwenKey = false
    @State private var removeOpenAIKey = false
    @State private var saveFeedback: SaveFeedback?

    init(state: AppState) {
        self.state = state
        _draft = State(initialValue: state.settings)
        _xAIKey = State(initialValue: "")
        _qwenKey = State(initialValue: "")
        _openAIKey = State(initialValue: "")
    }

    var body: some View {
        Form {
            accountSection
            appearanceSection
            dictionarySection
            languageSection
            providerSection
            Section {
                LabeledContent("Version", value: AppVersion.displayName)
                if let saveFeedback {
                    Label(saveFeedback.message, systemImage: saveFeedback.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(saveFeedback.succeeded ? Palette.gold : Palette.dim)
                        .accessibilityLabel(saveFeedback.succeeded ? "Settings saved" : "Settings could not be saved")
                        .accessibilityValue(saveFeedback.message)
                }
            }
            .listRowBackground(Palette.panel)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .navigationTitle("Settings")
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .navigationBarBackButtonHidden(true)
#endif
        .toolbar {
#if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button("Revert", action: revert)
                    .disabled(!isDirty)
                    .accessibilityLabel("Revert unsaved settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save Settings", action: save)
                    .disabled(!isDirty)
                    .accessibilityLabel("Save settings")
            }
#else
            ToolbarItem(placement: .cancellationAction) {
                Button("Revert", action: revert)
                    .disabled(!isDirty)
                    .accessibilityLabel("Revert unsaved settings")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save Settings", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty)
                    .accessibilityLabel("Save settings")
            }
#endif
        }
        .tint(Palette.terracotta)
    }

    private var isDirty: Bool {
        draft != state.settings
            || !xAIKey.isEmpty
            || !qwenKey.isEmpty
            || !openAIKey.isEmpty
            || removeXAIKey
            || removeQwenKey
            || removeOpenAIKey
    }

    private func revert() {
        draft = state.settings
        xAIKey = ""
        qwenKey = ""
        openAIKey = ""
        removeXAIKey = false
        removeQwenKey = false
        removeOpenAIKey = false
        saveFeedback = nil
    }

    private var accountSection: some View {
        Section("Account") {
            AccountSessionView(session: state.account)
        }
        .listRowBackground(Palette.panel)
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            VStack(alignment: .leading, spacing: 12) {
                settingRow("Theme") {
                    Picker("Theme", selection: $draft.appearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.menuLabel).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .tint(Palette.terracotta)
                }
                settingRow("Text size") {
                    HStack(spacing: 12) {
                        Slider(value: $draft.readerFontScale, in: 0.65...1.6, step: 0.05)
                            .tint(Palette.terracotta)
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
                            .tint(Palette.terracotta)
                        Text(String(format: "%.1fx", draft.readerLineSpacing))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                settingRow("Word spacing") {
                    HStack(spacing: 12) {
                        Slider(value: $draft.readerWordSpacing, in: 0...12, step: 1)
                            .tint(Palette.terracotta)
                        Text("\(Int(draft.readerWordSpacing)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                settingRow("Margins") {
                    HStack(spacing: 12) {
                        Slider(value: $draft.readerMargin, in: 16...96, step: 4)
                            .tint(Palette.terracotta)
                        Text("\(Int(draft.readerMargin)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                helper("These reading controls are shared by the macOS and iPad readers.")
            }
            .tint(Palette.terracotta)
        }
        .listRowBackground(Palette.panel)
    }

    private var dictionarySection: some View {
        Section("Apple Dictionary") {
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
                Button("Open Dictionary.app") { DictionaryLookup.openDictionaryApp() }
                    .frame(minHeight: 44, alignment: .leading)
#endif
            }
        }
        .listRowBackground(Palette.panel)
    }

    private var languageSection: some View {
        Section("Languages") {
            VStack(alignment: .leading, spacing: 12) {
                settingRow("Default audiobook language") {
                    Picker("Default audiobook language", selection: $draft.transcriptionLanguage) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(language.menuLabel).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                }
                settingRow("Reader level") {
                    Picker("Reader level", selection: $draft.readerLanguageLevel) {
                        ForEach(ReaderLanguageLevel.allCases) { level in
                            Text(level.menuLabel).tag(level.rawValue)
                        }
                    }
                    .labelsHidden()
                }
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
                helper("The default audiobook language is used for new books; each book can override it in the Library or Reader. Reader level keeps AI language notes selective. Translate into controls explanations and study tools.")
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
        }
        .listRowBackground(Palette.panel)
    }

    private var providerSection: some View {
        Section("LLM provider") {
            VStack(alignment: .leading, spacing: 12) {
                if let warning = state.credentialMigrationWarning {
                    migrationWarning(warning)
                }
                settingRow("Provider") {
                    Picker("Provider", selection: $draft.llmProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.menuLabel).tag(provider.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Divider().overlay(Palette.line)

                switch draftProvider {
                case .managedQwen:
                    managedQwenSettings
                case .grok:
                    grokSettings
                case .qwenCloud:
                    qwenSettings
                case .openAI:
                    openAISettings
                case .appleFoundation:
                    appleFoundationSettings
                }
            }
        }
        .listRowBackground(Palette.panel)
    }

    private var managedQwenSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            helper("Uses the signed-in AudioReader account. The Worker holds the Qwen key and policy. No local API key or endpoint.")
            settingRow("Connection") {
                connectionStatus(
                    state.account.mode.isSignedIn ? "Ready — signed-in account" : "Sign in required",
                    ready: state.account.mode.isSignedIn
                )
            }
            alignedHelper(
                !state.account.flagEnabled("managed_qwen")
                    ? "Managed Qwen is turned off for this product right now."
                    : state.account.mode.isSignedIn
                    ? "Translations, summaries, and chapter chat go to the product API. Exact translations can reuse the shared cache."
                    : "Open Account above, sign in, then save Managed Qwen.",
                muted: true
            )
            settingRow("Model") {
                Text("qwen3.7-plus (server policy)")
                    .foregroundStyle(Palette.ink)
            }
        }
    }

    private var appleFoundationSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            helper("On-device Apple Intelligence. No API key, endpoint, or vault credential. Requires Apple Intelligence on this Mac or iPad.")
            settingRow("Connection") {
                connectionStatus(
                    state.appleIntelligenceAvailability.shortLabel,
                    ready: state.appleIntelligenceAvailability.isReady
                )
            }
            alignedHelper(state.appleIntelligenceAvailability.userMessage, muted: true)
        }
        .onAppear { state.refreshAppleIntelligenceAvailability() }
    }

    private var grokSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            helper("Choose either a Grok Build sign-in or the supported xAI API. API credentials and endpoints apply only to API-key mode.")
            settingRow("Authentication") {
#if os(macOS)
                Picker("Authentication", selection: $draft.grokAuthentication) {
                    ForEach(GrokAuthentication.allCases) { authentication in
                        Text(authentication.menuLabel).tag(authentication.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
#else
                Text("API key")
                    .onAppear { draft.grokAuthentication = GrokAuthentication.apiKey.rawValue }
#endif
            }

            if draftGrokAuthentication == .grokBuild {
                legalWarning(
                    "Using a Grok Build sign-in through AudioReader may violate xAI's terms. Review the current terms before continuing.",
                    linkLabel: "Review xAI terms",
                    url: URL(string: "https://x.ai/legal/terms-of-service")!
                )
                settingRow("Connection") {
                    connectionStatus(
                        GrokBuildCredentialProvider.sourceLabel,
                        ready: GrokBuildCredentialProvider.load() != nil
                    )
                }
                alignedHelper("Run `grok login` in Terminal to manage this provider-owned session. AudioReader does not save the Grok Build credential.", muted: true)
            } else {
                settingRow("Connection") {
                    connectionStatus(APIKeyStore.sourceLabel, ready: APIKeyStore.isConfigured)
                }
                apiKeyRow(
                    label: "xAI API key",
                    placeholder: "Enter a new XAI_API_KEY",
                    key: $xAIKey,
                    removeSavedKey: $removeXAIKey,
                    hasSavedKey: APIKeyStore.hasSavedKey
                )
                settingRow("Endpoint") {
                    endpointField(
                        "xAI API endpoint",
                        value: $draft.grokEndpoint,
                        defaultValue: LLMProvider.grok.defaultEndpoint
                    )
                }
                if state.isLoadingGrokModels {
                    modelLoadingRow("Refreshing the xAI model list…")
                } else if let message = state.grokModelsMessage {
                    alignedHelper(message)
                }
                HStack {
                    Button {
                        Task {
                            if let models = await state.retrieveGrokModels(baseURL: draft.grokEndpoint, apiKey: xAIKey) {
                                normalizeDraftModel(models, selection: &draft.grokModel, preferred: "grok-4.6")
                                normalizeDraftGrokEffort()
                            }
                        }
                    } label: {
                        Label("Retrieve xAI Models", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.isLoadingGrokModels)
                }
                alignedHelper("\(state.grokModels.count) language models in the current catalog.", muted: true)
            }
            settingRow("Model") {
                Picker("Model", selection: $draft.grokModel) {
                    ForEach(grokTextModels) { model in
                        Text(model.menuLabel).tag(model.id)
                    }
                }
                .labelsHidden()
                .onChange(of: draft.grokModel) { _, _ in normalizeDraftGrokEffort() }
            }
            if !draftGrokEfforts.isEmpty {
                settingRow("Reasoning effort") {
                    Picker("Reasoning effort", selection: $draft.grokEffort) {
                        ForEach(draftGrokEfforts) { effort in
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
                connectionStatus(QwenAPIKeyStore.sourceLabel, ready: QwenAPIKeyStore.isConfigured)
            }
            apiKeyRow(
                label: "DashScope API key",
                placeholder: "Enter a new DASHSCOPE_API_KEY",
                key: $qwenKey,
                removeSavedKey: $removeQwenKey,
                hasSavedKey: QwenAPIKeyStore.hasSavedKey
            )
            settingRow("Endpoint") {
                endpointField(
                    "QwenCloud endpoint",
                    value: $draft.qwenEndpoint,
                    defaultValue: LLMProvider.qwenCloud.defaultEndpoint
                )
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
                    ProgressView().controlSize(.small)
                    Text("Refreshing the QwenCloud model list…")
                        .font(.footnote)
                        .foregroundStyle(Palette.dim)
                }
            } else if let message = state.qwenModelsMessage {
                alignedHelper(message)
            }
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
            alignedHelper("\(state.qwenModels.count) catalog models. Only text-generation models appear in this picker.", muted: true)
        }
    }

    private var openAISettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            helper("Use an existing Codex ‘Sign in with ChatGPT’ session for ChatGPT-plan access on macOS, or use an OpenAI API key for usage-based access on macOS and iPadOS. The two modes keep separate billing and workspace policies.")
            settingRow("Authentication") {
#if os(macOS)
                Picker("Authentication", selection: $draft.openAIAuthentication) {
                    ForEach(OpenAIAuthentication.allCases) { authentication in
                        Text(authentication.menuLabel).tag(authentication.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: draft.openAIAuthentication) { _, _ in normalizeDraftOpenAIEffort() }
#else
                Text("API key")
                    .onAppear { draft.openAIAuthentication = OpenAIAuthentication.apiKey.rawValue }
#endif
            }

            if draftOpenAIAuthentication == .chatGPT {
                legalWarning(
                    "Using a ChatGPT-plan Codex session through AudioReader may violate OpenAI's terms. Review the current terms before continuing.",
                    linkLabel: "Review OpenAI terms",
                    url: URL(string: "https://openai.com/policies/terms-of-use/")!
                )
                settingRow("Connection") {
                    connectionStatus(
                        state.codexLoginStatus,
                        ready: state.codexLoginStatus.localizedCaseInsensitiveContains("logged in")
                    )
                }
                alignedHelper("Codex: \(CodexCLIClient.executableLabel)", muted: true)
                HStack(spacing: 8) {
                    if state.isCheckingCodexLogin {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await state.refreshCodexLoginStatus() }
                    } label: {
                        Label("Check Codex Login", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.isCheckingCodexLogin)
                }
                .frame(minHeight: 44, alignment: .leading)
                alignedHelper("If needed, run `codex login` in Terminal and choose Sign in with ChatGPT. AudioReader prefers Codex's native executable and never reads or displays the cached OAuth tokens.", muted: true)
            } else {
                settingRow("Connection") {
                    connectionStatus(OpenAIAPIKeyStore.sourceLabel, ready: OpenAIAPIKeyStore.isConfigured)
                }
                apiKeyRow(
                    label: "OpenAI API key",
                    placeholder: "Enter a new OPENAI_API_KEY",
                    key: $openAIKey,
                    removeSavedKey: $removeOpenAIKey,
                    hasSavedKey: OpenAIAPIKeyStore.hasSavedKey
                )
                settingRow("Endpoint") {
                    endpointField(
                        "OpenAI API endpoint",
                        value: $draft.openAIEndpoint,
                        defaultValue: LLMProvider.openAI.defaultEndpoint
                    )
                }
                if state.isLoadingOpenAIModels {
                    modelLoadingRow("Refreshing the OpenAI model list…")
                } else if let message = state.openAIModelsMessage {
                    alignedHelper(message)
                }
                HStack {
                    Button {
                        Task {
                            if let models = await state.retrieveOpenAIModels(baseURL: draft.openAIEndpoint, apiKey: openAIKey) {
                                normalizeDraftModel(models, selection: &draft.openAIModel, preferred: "gpt-5.6-luna")
                                normalizeDraftOpenAIEffort()
                            }
                        }
                    } label: {
                        Label("Retrieve OpenAI Models", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.isLoadingOpenAIModels)
                }
                alignedHelper("\(state.openAIModels.count) text models in the current catalog.", muted: true)
            }

            settingRow("Model") {
                Picker("Model", selection: $draft.openAIModel) {
                    ForEach(openAITextModels) { model in
                        Text(model.menuLabel).tag(model.id)
                    }
                }
                .labelsHidden()
                .onChange(of: draft.openAIModel) { _, _ in normalizeDraftOpenAIEffort() }
            }
            if !draftOpenAIEfforts.isEmpty {
                settingRow("Reasoning effort") {
                    Picker("Reasoning effort", selection: $draft.openAIEffort) {
                        ForEach(draftOpenAIEfforts) { effort in
                            Text(effort.menuLabel).tag(effort.rawValue)
                        }
                    }
                    .labelsHidden()
                }
            }
            alignedHelper("Effort choices follow the selected model. API model discovery needs an OpenAI API key; ChatGPT-plan sessions do not expose that endpoint.", muted: true)
        }
        .task {
            if draftOpenAIAuthentication == .chatGPT {
                await state.refreshCodexLoginStatus()
            }
        }
    }

    private var draftProvider: LLMProvider {
        LLMProvider(rawValue: draft.llmProvider) ?? .grok
    }

    private var draftOpenAIAuthentication: OpenAIAuthentication {
        OpenAIAuthentication(rawValue: draft.openAIAuthentication) ?? .chatGPT
    }

    private var draftGrokAuthentication: GrokAuthentication {
        GrokAuthentication(rawValue: draft.grokAuthentication) ?? .grokBuild
    }

    private var qwenTextModels: [LLMModelInfo] {
        var models = state.qwenModels.filter(\.supportsText)
        if !models.contains(where: { $0.id == draft.qwenModel }) {
            models.append(.init(id: draft.qwenModel, brand: "Custom", capabilities: "Custom model ID", supportsText: true))
        }
        return models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private var grokTextModels: [LLMModelInfo] {
        selectableModels(state.grokModels, selectedID: draft.grokModel)
    }

    private var openAITextModels: [LLMModelInfo] {
        selectableModels(state.openAIModels, selectedID: draft.openAIModel)
    }

    private var draftGrokEfforts: [GrokEffort] {
        GrokRequestPolicy.supportedEfforts(model: draft.grokModel)
    }

    private var draftOpenAIEfforts: [OpenAIEffort] {
        if draftOpenAIAuthentication == .chatGPT { return OpenAIEffort.allCases }
        return OpenAIRequestPolicy.supportedAPIEfforts(model: draft.openAIModel)
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

    private func normalizeDraftGrokEffort() {
        guard !draftGrokEfforts.isEmpty,
              !draftGrokEfforts.contains(where: { $0.rawValue == draft.grokEffort })
        else { return }
        draft.grokEffort = draftGrokEfforts.contains(.medium) ? GrokEffort.medium.rawValue : draftGrokEfforts[0].rawValue
    }

    private func normalizeDraftOpenAIEffort() {
        guard !draftOpenAIEfforts.isEmpty,
              !draftOpenAIEfforts.contains(where: { $0.rawValue == draft.openAIEffort })
        else { return }
        draft.openAIEffort = draftOpenAIEfforts.contains(.medium) ? OpenAIEffort.medium.rawValue : draftOpenAIEfforts[0].rawValue
    }

    private func selectableModels(_ models: [LLMModelInfo], selectedID: String) -> [LLMModelInfo] {
        var selectable = models.filter(\.supportsText)
        if !selectable.contains(where: { $0.id == selectedID }) {
            selectable.append(.init(id: selectedID, brand: "Custom", capabilities: "Custom model ID", supportsText: true))
        }
        return selectable.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func normalizeDraftModel(_ models: [LLMModelInfo], selection: inout String, preferred: String) {
        let selectable = models.filter(\.supportsText)
        guard !selectable.contains(where: { $0.id == selection }) else { return }
        selection = selectable.first(where: { $0.id == preferred })?.id ?? selectable.first?.id ?? selection
    }

    private func modelLoadingRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Palette.dim)
        }
        .frame(minHeight: 44, alignment: .leading)
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.ink)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func helper(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func alignedHelper(_ text: String, muted: Bool = false) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(muted ? Palette.mute : Palette.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectionStatus(_ text: String, ready: Bool) -> some View {
        Label(text, systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(ready ? Palette.gold : Palette.dim)
            .frame(minHeight: 44, alignment: .leading)
    }

    private func endpointField(
        _ placeholder: String,
        value: Binding<String>,
        defaultValue: String
    ) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
            Button("Reset") { value.wrappedValue = defaultValue }
                .disabled(value.wrappedValue == defaultValue)
        }
    }

    private func apiKeyRow(
        label: String,
        placeholder: String,
        key: Binding<String>,
        removeSavedKey: Binding<Bool>,
        hasSavedKey: Bool
    ) -> some View {
        settingRow(label) {
            VStack(alignment: .leading, spacing: 8) {
                SecureField(placeholder, text: key)
                    .textFieldStyle(.roundedBorder)
                    .disabled(removeSavedKey.wrappedValue)
                HStack(spacing: 8) {
                    Text(hasSavedKey
                         ? (removeSavedKey.wrappedValue ? "Saved key will be removed." : "Leave blank to keep the encrypted key.")
                         : "Encrypted locally when you save settings.")
                        .font(.footnote)
                        .foregroundStyle(Palette.dim)
                    Spacer(minLength: 0)
                    if hasSavedKey {
                        Button(removeSavedKey.wrappedValue ? "Keep key" : "Remove key") {
                            removeSavedKey.wrappedValue.toggle()
                            if removeSavedKey.wrappedValue { key.wrappedValue = "" }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func legalWarning(_ text: String, linkLabel: String, url: URL) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.gold)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Link(linkLabel, destination: url)
                    .font(.footnote.weight(.medium))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.goldSoft)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func migrationWarning(_ text: String) -> some View {
        Label(text, systemImage: "lock.trianglebadge.exclamationmark")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Palette.ink)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.goldSoft)
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
        let xAIKeySaved = removeXAIKey ? APIKeyStore.clear() : APIKeyStore.save(xAIKey)
        let qwenKeySaved = removeQwenKey ? QwenAPIKeyStore.clear() : QwenAPIKeyStore.save(qwenKey)
        let openAIKeySaved = removeOpenAIKey ? OpenAIAPIKeyStore.clear() : OpenAIAPIKeyStore.save(openAIKey)

        guard settingsSaved else {
            saveFeedback = .init(message: "Settings could not be written to disk. Your changes were not applied.", succeeded: false)
            return
        }

        state.settings = draft
        state.selectedDictionaryName = draft.preferredDictionary
        xAIKey = ""
        qwenKey = ""
        openAIKey = ""
        removeXAIKey = false
        removeQwenKey = false
        removeOpenAIKey = false

        if xAIKeySaved && qwenKeySaved && openAIKeySaved {
            saveFeedback = .init(message: "Settings saved. API keys are protected in the encrypted local vault.", succeeded: true)
            if ![APIKeyStore.fileURL, QwenAPIKeyStore.fileURL, OpenAIAPIKeyStore.fileURL]
                .contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                state.credentialMigrationWarning = nil
            }
        } else {
            saveFeedback = .init(message: "Settings saved, but one or more API keys could not be stored.", succeeded: false)
        }

        Task {
            switch draftProvider {
            case .managedQwen:
                break
            case .grok where draftGrokAuthentication == .apiKey && xAIKeySaved:
                await state.refreshGrokModels()
                draft.grokModel = state.settings.grokModel
            case .qwenCloud where qwenKeySaved:
                await state.refreshQwenModels()
                draft.qwenModel = state.settings.qwenModel
            case .openAI where draftOpenAIAuthentication == .apiKey && openAIKeySaved:
                await state.refreshOpenAIModels()
                draft.openAIModel = state.settings.openAIModel
            case .openAI where draftOpenAIAuthentication == .chatGPT:
                await state.refreshCodexLoginStatus()
            case .appleFoundation:
                state.refreshAppleIntelligenceAvailability()
            default:
                break
            }
        }
    }
}

private struct SaveFeedback {
    let message: String
    let succeeded: Bool
}
